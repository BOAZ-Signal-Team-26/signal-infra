#!/usr/bin/env bash
# 6절 11 / scripts/aws/README.md 7번: RDS DB·계정 초기화 및 Flyway 후 권한 부여(PM 담당)
#
# 전제:
# - 로컬에서 Session Manager 원격 포트 전달로 RDS 5432를 localhost:${RDS_LOCAL_PORT:-15432}에 연결해 둠
# - SSM에 /signal/rds/{master,owner,pipeline,reader,airflow}_password가 저장되어 있음
#   (없으면 --generate-secrets 옵션으로 00-put-secret.sh를 먼저 호출하거나 수동 생성)
# - 비밀번호는 명령 인자(-v)에 직접 노출하지 않고 권한 600 임시 파일(\set)로만 전달하며 종료·신호 시 삭제한다
#
# 사용:
#   # 1단계 (Flyway migrate 전, signal_admin으로 실행):
#   scripts/aws/07-rds-init.sh --phase roles [--generate-secrets]
#
#   # 2단계 (Flyway migrate 직후, signal_owner로 실행):
#   scripts/aws/07-rds-init.sh --phase grants

source "$(dirname "$0")/lib.sh"
require aws psql sed

SQL_DIR="$SCRIPT_DIR/sql"
RDS_HOST=${RDS_LOCAL_HOST:-localhost}
RDS_PORT=${RDS_LOCAL_PORT:-15432}
RDS_SSLMODE=${RDS_SSLMODE:-require}
MASTER_USER=${RDS_MASTER_USER:-signal_admin}
PHASE=""
GENERATE_SECRETS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      PHASE="${2:-}"
      shift 2
      ;;
    --generate-secrets)
      GENERATE_SECRETS=1
      shift
      ;;
    *)
      die "알 수 없는 인자: $1 (사용: --phase roles|grants [--generate-secrets])"
      ;;
  esac
done

[[ "$PHASE" == "roles" || "$PHASE" == "grants" ]] ||
  die "--phase roles 또는 --phase grants를 지정한다"

TMP_VARS=""
cleanup() {
  [[ -n "$TMP_VARS" && -f "$TMP_VARS" ]] && rm -f "$TMP_VARS"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

validate_secret() {
  local name=$1 val=$2
  [[ -n "$val" ]] || die "$name 값이 비었다"
  [[ "$val" != *$'\n'* && "$val" != *$'\r'* ]] || die "$name 값에 줄바꿈이 포함되어 있다"
}

escape_psql_sq() {
  # psql \set 단일 따옴표 리터럴 이스케이프(' -> '')
  printf '%s' "$1" | sed "s/'/''/g"
}

run_roles_phase() {
  if [[ "$GENERATE_SECRETS" == 1 ]]; then
    for name in owner_password pipeline_password reader_password airflow_password; do
      if ssm_param_exists "/signal/rds/$name"; then
        log "SSM 비밀값 있음(유지): /signal/rds/$name"
      else
        "$SCRIPT_DIR/00-put-secret.sh" "/signal/rds/$name" --generate password
      fi
    done
  fi

  local master_pw owner_pw pipeline_pw reader_pw airflow_pw
  master_pw=$(ssm_secret /signal/rds/master_password) || die "/signal/rds/master_password 없음"
  owner_pw=$(ssm_secret /signal/rds/owner_password) || die "/signal/rds/owner_password 없음"
  pipeline_pw=$(ssm_secret /signal/rds/pipeline_password) || die "/signal/rds/pipeline_password 없음"
  reader_pw=$(ssm_secret /signal/rds/reader_password) || die "/signal/rds/reader_password 없음"
  airflow_pw=$(ssm_secret /signal/rds/airflow_password) || die "/signal/rds/airflow_password 없음"

  validate_secret /signal/rds/master_password "$master_pw"
  validate_secret /signal/rds/owner_password "$owner_pw"
  validate_secret /signal/rds/pipeline_password "$pipeline_pw"
  validate_secret /signal/rds/reader_password "$reader_pw"
  validate_secret /signal/rds/airflow_password "$airflow_pw"

  TMP_VARS=$(mktemp "${TMPDIR:-/tmp}/signal-rds-init.XXXXXX")
  chmod 600 "$TMP_VARS"
  {
    printf "\\set owner_pw '%s'\n" "$(escape_psql_sq "$owner_pw")"
    printf "\\set pipeline_pw '%s'\n" "$(escape_psql_sq "$pipeline_pw")"
    printf "\\set reader_pw '%s'\n" "$(escape_psql_sq "$reader_pw")"
    printf "\\set airflow_pw '%s'\n" "$(escape_psql_sq "$airflow_pw")"
    cat "$SQL_DIR/01-init-roles-dbs.sql"
  } >"$TMP_VARS"

  log "1단계 실행: 계정 4개·airflow DB 생성 및 signal 소유자 전환 ($MASTER_USER@$RDS_HOST:$RDS_PORT)"
  PGPASSWORD="$master_pw" psql -X \
    "host=$RDS_HOST port=$RDS_PORT dbname=signal user=$MASTER_USER sslmode=$RDS_SSLMODE" \
    -v ON_ERROR_STOP=1 \
    -f "$TMP_VARS"
  log "1단계 완료. 다음으로 signal-pipeline에서 flyway -environment=rds migrate를 실행한다"
}

run_grants_phase() {
  local owner_pw
  owner_pw=$(ssm_secret /signal/rds/owner_password) || die "/signal/rds/owner_password 없음"
  validate_secret /signal/rds/owner_password "$owner_pw"

  log "2단계 실행: signal_pipeline(3스키마 쓰기)·signal_reader(mart 읽기) 권한 부여 (signal_owner@$RDS_HOST:$RDS_PORT)"
  PGPASSWORD="$owner_pw" psql -X \
    "host=$RDS_HOST port=$RDS_PORT dbname=signal user=signal_owner sslmode=$RDS_SSLMODE" \
    -v ON_ERROR_STOP=1 \
    -f "$SQL_DIR/02-grant-signal-privs.sql"
  log "2단계 완료"
}

if [[ "$PHASE" == "roles" ]]; then
  run_roles_phase
else
  run_grants_phase
fi
