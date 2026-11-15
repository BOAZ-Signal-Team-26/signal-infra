#!/usr/bin/env bash
# 6절 6(뒷부분): AWS Budgets 동작. 실제 비용이 월 상한(예산 monthly-50usd)의 100%에 닿으면 승인 없이 EC2를 중지한다
#
# 값(11월 8일 결정, storage-design.md 3.10)
# - 기존 예산 monthly-50usd(PM이 만듦)에 붙인다. 실제 비용(ACTUAL) 100%, RUN_SSM_DOCUMENTS/STOP_EC2_INSTANCES, 자동 승인
# - 실행 역할 signal-budgets-stop-ec2: budgets.amazonaws.com이 맡음(같은 계정의 예산만, aws:SourceAccount·aws:SourceArn 조건)
#   AWS 관리형 정책 AWSBudgetsActions_RolePolicyForResourceAdministrationWithSSM을 붙인다.
#   정책 내용 확인은 구축 때 하고, 넓으면 ec2:StopInstances·ssm:StartAutomationExecution만 넣은 정책으로 바꾼다(결정 기록의 남은 확인)
# - 알림 수신자 PM·데이터 엔지니어링·인프라. 메일 주소는 저장소에 넣지 않고 BUDGET_EMAILS로 받는다
# - RDS·S3는 데이터 보존을 위해 건드리지 않는다
#
# 사용: BUDGET_EMAILS="<메일> <메일>" scripts/aws/05-budgets.sh   (04 뒤. 다시 실행하면 인스턴스 ID·수신자를 맞춤)
# 시험(6절 12): BUDGET_THRESHOLD=1 로 실행해 중지되는지 본 뒤 기본값(100)으로 다시 실행한다

source "$(dirname "$0")/lib.sh"
require aws jq

ROLE=signal-budgets-stop-ec2
BUDGET=monthly-50usd
THRESHOLD="${BUDGET_THRESHOLD:-100}"

ensure_role() {
  local trust
  trust=$(render "$POLICY_DIR/budgets-trust.json" "ACCOUNT_ID=$(account_id)")
  if role_exists "$ROLE"; then
    aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$trust"
    log "역할 있음: $ROLE (신뢰 정책 갱신)"
  else
    # shellcheck disable=SC2046
    aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$trust" \
      --description "AWS Budgets action: stop signal EC2" --tags $(tags_kv "$ROLE") >/dev/null
    log "역할 만듦: $ROLE"
  fi
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AWSBudgetsActions_RolePolicyForResourceAdministrationWithSSM
}

main() {
  local account instance role_arn subscribers existing definition threshold
  [[ -n "${BUDGET_EMAILS:-}" ]] || die "BUDGET_EMAILS(동작 알림 받을 메일, 공백으로 구분)가 필요하다"
  account=$(account_id)
  aws budgets describe-budget --account-id "$account" --budget-name "$BUDGET" >/dev/null ||
    die "예산 ${BUDGET}이 없다(PM이 만든 예산 이름을 확인한다)"
  instance=$(instance_id)
  [[ -n "$instance" && "$instance" != *[[:space:]]* ]] || die "signal-airflow 인스턴스가 하나가 아니다: '$instance'"
  ensure_role
  role_arn="arn:aws:iam::$account:role/$ROLE"
  local -a emails
  read -ra emails <<<"$BUDGET_EMAILS"
  subscribers=$(printf '%s\n' "${emails[@]}" | jq -R '{SubscriptionType: "EMAIL", Address: .}' | jq -s -c .)
  definition=$(jq -n -c --arg region "$AWS_REGION" --arg id "$instance" \
    '{SsmActionDefinition: {ActionSubType: "STOP_EC2_INSTANCES", Region: $region, InstanceIds: [$id]}}')
  threshold="ActionThresholdValue=$THRESHOLD,ActionThresholdType=PERCENTAGE"
  existing=$(aws budgets describe-budget-actions-for-budget --account-id "$account" --budget-name "$BUDGET" \
    --query "Actions[?ActionType=='RUN_SSM_DOCUMENTS' && Definition.SsmActionDefinition.ActionSubType=='STOP_EC2_INSTANCES'].ActionId | [0]" \
    --output text | none_to_empty)
  if [[ -z "$existing" ]]; then
    aws budgets create-budget-action --account-id "$account" --budget-name "$BUDGET" \
      --notification-type ACTUAL --action-type RUN_SSM_DOCUMENTS \
      --action-threshold "$threshold" --definition "$definition" \
      --execution-role-arn "$role_arn" --approval-model AUTOMATIC \
      --subscribers "$subscribers" >/dev/null
    log "예산 동작 만듦: $BUDGET 실제 비용 $THRESHOLD% → EC2 $instance 중지(자동 승인)"
  else
    aws budgets update-budget-action --account-id "$account" --budget-name "$BUDGET" \
      --action-id "$existing" --notification-type ACTUAL \
      --action-threshold "$threshold" --definition "$definition" \
      --execution-role-arn "$role_arn" --approval-model AUTOMATIC \
      --subscribers "$subscribers" >/dev/null
    log "예산 동작 갱신: $existing ($THRESHOLD%, EC2 $instance)"
  fi
  log "05 완료"
}

main "$@"
