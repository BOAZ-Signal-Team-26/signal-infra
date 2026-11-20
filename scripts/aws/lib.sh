# shellcheck shell=bash
# scripts/aws/ 단계 스크립트가 같이 쓰는 함수. 단독 실행하지 않고 `source`로 읽는다.
#
# 규칙(docs/storage-design.md 6절, 11월 8일 결정)
# - 자원 이름은 signal-{자원}[-{가용 영역}], 모든 자원에 태그 Project=signal, Name=<이름>
# - 단계마다 Name 태그(또는 이름)로 먼저 조회하고 없을 때만 만든다. 그래서 같은 스크립트를 다시 실행해도 된다
# - 만든 자원 ID를 파일로 남기지 않는다. 필요한 ID는 태그로 다시 조회한다
# - 계정 ID·공인 IP·개인 계정명·메일 주소는 저장소에 적지 않는다. 계정 ID는 실행 때 STS로 읽는다
# - 비밀값은 SSM Parameter Store에서 읽어 넘기고 화면에 출력하지 않는다

set -euo pipefail

export AWS_REGION="${AWS_REGION:-ap-northeast-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

PROJECT=signal

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die() {
  log "중단: $*"
  exit 1
}

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd 명령이 필요하다"
  done
}

# describe 결과가 없을 때 AWS CLI가 내는 "None"·빈 문자열을 빈 값으로 맞춘다
none_to_empty() {
  local v
  v=$(cat)
  if [[ "$v" == "None" || "$v" == "null" ]]; then v=""; fi
  printf '%s' "$v"
}

account_id() {
  if [[ -z "${ACCOUNT_ID:-}" ]]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export ACCOUNT_ID
  fi
  printf '%s' "$ACCOUNT_ID"
}

# EC2 tag-specifications 값. 사용: tag_spec vpc signal-vpc
tag_spec() {
  printf 'ResourceType=%s,Tags=[{Key=Project,Value=%s},{Key=Name,Value=%s}]' "$1" "$PROJECT" "$2"
}

# Key=..,Value=.. 목록 형식(RDS·IAM·SSM 등). 사용: tags_kv signal-db
tags_kv() {
  printf 'Key=Project,Value=%s Key=Name,Value=%s' "$PROJECT" "$1"
}

ec2_filter_name() {
  printf 'Name=tag:Name,Values=%s Name=tag:Project,Values=%s' "$1" "$PROJECT"
}

vpc_id() {
  # shellcheck disable=SC2046
  aws ec2 describe-vpcs --filters $(ec2_filter_name signal-vpc) \
    --query 'Vpcs[0].VpcId' --output text | none_to_empty
}

subnet_id() {
  # shellcheck disable=SC2046
  aws ec2 describe-subnets --filters $(ec2_filter_name "$1") \
    --query 'Subnets[0].SubnetId' --output text | none_to_empty
}

sg_id() {
  local vpc
  vpc=$(vpc_id)
  [[ -n "$vpc" ]] || return 0
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$vpc" \
    --query 'SecurityGroups[0].GroupId' --output text | none_to_empty
}

route_table_id() {
  # shellcheck disable=SC2046
  aws ec2 describe-route-tables --filters $(ec2_filter_name "$1") \
    --query 'RouteTables[0].RouteTableId' --output text | none_to_empty
}

eip_allocation_id() {
  # shellcheck disable=SC2046
  aws ec2 describe-addresses --filters $(ec2_filter_name signal-eip) \
    --query 'Addresses[0].AllocationId' --output text | none_to_empty
}

# 종료(terminated)·종료 중이 아닌 signal-airflow 인스턴스
instance_id() {
  # shellcheck disable=SC2046
  aws ec2 describe-instances --filters $(ec2_filter_name signal-airflow) \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text | none_to_empty
}

bucket_name() {
  printf 'signal-data-%s-%s-an' "$(account_id)" "$AWS_REGION"
}

role_exists() { aws iam get-role --role-name "$1" >/dev/null 2>&1; }

ssm_param_exists() { aws ssm get-parameter --name "$1" >/dev/null 2>&1; }

# SecureString 값을 표준 출력으로 낸다. 호출하는 쪽이 변수에 담고 화면에 찍지 않는다
ssm_secret() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query Parameter.Value --output text
}

# 비밀값이 든 요청 JSON을 표준 입력으로 받아 권한 600 임시 파일로 넘기고 지운다.
# 명령 인자(프로세스 목록)에 비밀값이 남지 않게 하려는 것. AWS CLI는 file:///dev/stdin을 읽지 못한다(macOS 확인).
# 서브셸의 EXIT trap으로 지우므로 명령 실패·Ctrl-C·종료 신호로 끝나도 파일이 남지 않는다.
# 사용: jq ... | with_json_file aws ssm put-parameter --cli-input-json
with_json_file() {
  (
    tmp=$(mktemp "${TMPDIR:-/tmp}/signal-request.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    chmod 600 "$tmp"
    cat >"$tmp"
    "$@" "file://$tmp"
  )
}

# String 파라미터를 만들거나 같은 이름이면 값을 바꾼다(비밀값이 아닌 것만)
ssm_put_string() {
  aws ssm put-parameter --name "$1" --type String --value "$2" --overwrite >/dev/null
}

# 고객 관리형 IAM 정책을 만들거나, 이미 있고 내용이 다르면 새 기본 버전으로 바꾼다.
# 버전이 5개(IAM 상한)면 기본이 아닌 것 중 가장 오래된 버전을 먼저 지운다. 사용: ensure_managed_policy NAME DOC DESCRIPTION
ensure_managed_policy() {
  local name=$1 doc=$2 description=$3 arn current_version current oldest
  arn="arn:aws:iam::$(account_id):policy/$name"
  if ! aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    aws iam create-policy --policy-name "$name" --policy-document "$doc" \
      --description "$description" --tags $(tags_kv "$name") >/dev/null
    log "정책 만듦: $name"
    return
  fi
  current_version=$(aws iam get-policy --policy-arn "$arn" --query Policy.DefaultVersionId --output text)
  current=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$current_version" \
    --query PolicyVersion.Document --output json | jq -S -c .)
  if [[ "$current" == "$(printf '%s' "$doc" | jq -S -c .)" ]]; then
    log "정책 있음: ${name}(내용 같음)"
    return
  fi
  if [[ "$(aws iam list-policy-versions --policy-arn "$arn" --query 'length(Versions)' --output text)" -ge 5 ]]; then
    oldest=$(aws iam list-policy-versions --policy-arn "$arn" \
      --query 'sort_by(Versions[?!IsDefaultVersion], &CreateDate)[0].VersionId' --output text)
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$oldest"
    log "정책 버전이 5개라 가장 오래된 ${oldest}를 지움: $name"
  fi
  aws iam create-policy-version --policy-arn "$arn" --policy-document "$doc" --set-as-default >/dev/null
  log "정책 갱신: ${name}(새 기본 버전)"
}

# 같은 값을 여러 번 쓰는 JSON 정책 파일의 자리표시자를 바꾼다. 사용: render FILE KEY=VALUE ...
render() {
  local file=$1 text kv
  shift
  text=$(cat "$file")
  for kv in "$@"; do
    text=${text//"{{${kv%%=*}}}"/${kv#*=}}
  done
  if [[ "$text" == *"{{"* ]]; then
    die "${file}에 바꾸지 않은 자리표시자가 남았다"
  fi
  printf '%s' "$text"
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
POLICY_DIR="$SCRIPT_DIR/policies"
export SCRIPT_DIR POLICY_DIR
