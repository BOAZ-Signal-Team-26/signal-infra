#!/usr/bin/env bash
# 6절 6(끝): 그룹 signal-team 보호 정책 signal-team-guardrails(storage-design.md 3.8)
#
# signal-team은 AWS 관리형 정책 PowerUserAccess라 IAM을 뺀 모든 서비스를 쓸 수 있다. 그래서 버킷 정책을 바꾸거나 지워
# raw/·runs/·assets/ 삭제 거부를 풀 수 있고, RDS 삭제 보호를 풀 수 있다. 이 정책은 그런 동작을 명시적으로 거부한다
# (11월 16일 PR #35 리뷰). Deny는 PowerUserAccess의 Allow보다 우선하고, PowerUserAccess는 IAM을 바꾸지 못해 스스로 떼지 못한다
# - 데이터 버킷: 버킷 정책 변경·삭제, 수명 주기·버전 관리·공개 차단 변경, 버킷 삭제
#   (수명 주기 만료는 S3가 직접 지우므로 버킷 정책의 삭제 거부로 막히지 않는다)
# - RDS signal-db: 수정·삭제(삭제 보호 해제, 백업 기간 변경 포함)
# - SSM /signal/rds/* 비밀번호 읽기. 분석 쪽 DB 접근 경로가 정해지면 필요한 것만 연다(3.8 「미결」)
# - SSM 경로 단위 조회(GetParametersByPath) 전체. 이 API는 요청한 경로로만 권한을 확인해 /signal을 조회하면
#   /signal/rds/* 거부와 관계없이 비밀번호가 돌아온다(Parameter Store 문서 「How Parameter Store authorizes parameter retrieval」).
#   이름으로 하나씩 읽는 것은 그대로 된다(11월 22일 PR #35 리뷰)
# - 데이터 버킷 deploy/ 쓰기·삭제와 CodeDeploy 배포 생성·설정 변경. 배포 묶음은 CodeDeploy 에이전트가 root로
#   실행하므로 배포 역할(GitHub Actions, Week 8)만 바꾼다(11월 22일 PR #35 리뷰)
# 관리자 사용자 2명(AdministratorAccess)에는 붙이지 않는다. 02·03 스크립트를 실행해야 하기 때문이다
#
# 사용: scripts/aws/06-team-guardrails.sh   (02·03 뒤. 다시 실행해도 됨. 내용이 바뀌면 새 정책 버전으로 바꿈)

source "$(dirname "$0")/lib.sh"
require aws jq

POLICY=signal-team-guardrails
GROUP=signal-team

main() {
  local doc arn
  doc=$(render "$POLICY_DIR/team-guardrails.json" "BUCKET=$(bucket_name)" \
    "REGION=$AWS_REGION" "ACCOUNT_ID=$(account_id)")
  ensure_managed_policy "$POLICY" "$doc" "Deny signal-team changing bucket protection, RDS and reading RDS passwords"
  aws iam get-group --group-name "$GROUP" >/dev/null 2>&1 ||
    die "그룹 ${GROUP}이 없다(6절 1 계정 준비를 먼저 한다)"
  arn="arn:aws:iam::$(account_id):policy/$POLICY"
  aws iam attach-group-policy --group-name "$GROUP" --policy-arn "$arn"
  log "${POLICY}를 그룹 ${GROUP}에 붙임"
  log "06 완료"
}

main "$@"
