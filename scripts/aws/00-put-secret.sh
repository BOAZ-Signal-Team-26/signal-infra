#!/usr/bin/env bash
# SSM Parameter Store에 SecureString 비밀값을 넣는다. 값은 화면·명령 인자·셸 기록에 남기지 않는다.
#
# 사용
#   scripts/aws/00-put-secret.sh /signal/rds/master_password --generate password   # 영문·숫자 32자 생성
#   scripts/aws/00-put-secret.sh /signal/airflow/fernet_key --generate fernet       # Airflow Fernet 키 생성
#   scripts/aws/00-put-secret.sh /signal/dart/api_key                               # 값을 입력받음(화면에 안 보임)
#   ... --overwrite                                                                  # 이미 있는 값을 바꿀 때만
#
# 구축 때 넣는 이름(11월 8일 결정, docs/storage-design.md 3.8)
#   03 전: /signal/rds/master_password
#   10 전: /signal/airflow/fernet_key, /signal/airflow/webserver_secret_key, /signal/airflow/admin_password,
#          /signal/rds/airflow_password(PM이 DB 계정을 만들 때 같은 값으로), /signal/dart/api_key

source "$(dirname "$0")/lib.sh"
require aws jq openssl

usage() {
  sed -n '2,13p' "$0" >&2
  exit 2
}

main() {
  local name=${1:-} mode="" overwrite=false value
  [[ "$name" == /signal/* ]] || usage
  shift
  while (($#)); do
    case $1 in
    --generate)
      mode=${2:-}
      shift 2
      ;;
    --overwrite)
      overwrite=true
      shift
      ;;
    *) usage ;;
    esac
  done
  if ssm_param_exists "$name" && ! $overwrite; then
    log "이미 있음: $name (바꾸려면 --overwrite)"
    return
  fi
  case $mode in
  password) value=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32) ;;
  fernet) value=$(openssl rand -base64 32 | tr '+/' '-_') ;;
  "")
    read -rsp "$name 값: " value
    echo >&2
    ;;
  *) usage ;;
  esac
  [[ -n "$value" ]] || die "값이 비었다"
  # 값을 명령 인자로 넘기지 않고 권한 600 임시 파일의 JSON으로 넘긴다
  VALUE="$value" jq -n --arg name "$name" --argjson ow "$overwrite" \
    '{Name: $name, Type: "SecureString", Value: env.VALUE, Overwrite: $ow}' |
    with_json_file aws ssm put-parameter --cli-input-json >/dev/null
  log "넣음: $name (SecureString)"
}

main "$@"
