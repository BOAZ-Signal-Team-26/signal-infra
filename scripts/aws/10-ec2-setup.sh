#!/usr/bin/env bash
# 6절 10: EC2 초기 설정. EC2 안에서 root로 실행한다(Session Manager 셸). user data로 쓰지 않는다.
#
# 하는 일(11월 8일 결정, docs/drafts 「EC2 설정」, storage-design.md 3.3·6절 10, signal-pipeline docs/architecture.md 2-3·4)
#  1. dnf upgrade 한 번(이후 수동)
#  2. 스왑 파일 2GB
#  3. 패키지: python3.12, PostgreSQL 16 클라이언트(pg_dump 포함), git, jq, AWS CLI
#  4. 사용자 airflow:airflow, 경로 /opt/signal/{airflow,airflow-venv,signal-pipeline,bin}, /var/lib/signal, /tmp/signal
#  5. Airflow 2.11.2를 /opt/signal/airflow-venv에 pip와 공식 제약 파일로 설치(postgres·amazon 추가 패키지)
#  6. uv(버전 고정 실행 파일, sha256 확인)와 signal-pipeline(공개 저장소, --pipeline-ref 기준)을 받아 uv.lock 그대로 설치
#  7. 비밀값은 SSM에서 읽는 명령(_cmd 설정)으로만 넘긴다. 서버에 평문 비밀값 파일을 두지 않는다
#  8. /etc/sysconfig/airflow(비밀 아닌 설정), systemd 서비스 2개(웹 서버·스케줄러, 실패 시 자동 재시작)
#  9. 로그: AIRFLOW_HOME/logs 14일 지난 파일 삭제 타이머, journald 상한 200MB
# 10. CodeDeploy 에이전트 설치(서울 리전 공식 설치 경로). 배포 설정은 Week 8
# 11. airflow db migrate, 관리자 계정 1개, pool signal_cpu(슬롯 2), 서비스 시작, 버전·디스크 기록
#
# 메타데이터 DB 연결은 sslmode=verify-full로 RDS 서버 인증서와 호스트 이름까지 확인한다. CA 묶음은 RDS 공식 경로
# (truststore.pki.rds.amazonaws.com, 리전 묶음)에서 받아 $BASE/rds-ca/에 둔다. 로컬 리허설은 --rds-ca-file로 시험용 CA를 준다
#
# 전제
# - 03-rds.sh가 SSM /signal/infra/rds_endpoint를 적었다
# - PM이 RDS에 airflow 데이터베이스와 airflow 계정을 만들었다. 그 비밀번호가 SSM /signal/rds/airflow_password에 있다
# - 00-put-secret.sh로 /signal/airflow/fernet_key, webserver_secret_key, admin_password를 넣었다
#
# 사용(EC2 Session Manager 셸에서)
#   sudo bash 10-ec2-setup.sh --pipeline-ref <signal-pipeline 태그 또는 브랜치> --raw-root s3://<버킷 이름>/
#   선택: --skip-upgrade --skip-swap --skip-codedeploy --no-start --rds-ca-file <PEM 경로>
# 다시 실행해도 된다. 이미 된 단계는 건너뛰고, 설정 파일과 서비스 파일은 이 스크립트 내용으로 다시 쓴다

set -euo pipefail

AIRFLOW_VERSION=2.11.2
PYTHON=/usr/bin/python3.12
UV_VERSION=0.11.2
PIPELINE_REPO=https://github.com/BOAZ-Signal-Team-26/signal-pipeline.git
BASE=/opt/signal
AIRFLOW_HOME=$BASE/airflow
AIRFLOW_VENV=$BASE/airflow-venv
PIPELINE_DIR=$BASE/signal-pipeline
BIN=$BASE/bin
STATE=/var/lib/signal
REGION="${AWS_REGION:-ap-northeast-2}"

PIPELINE_REF=""
RAW_ROOT=""
RDS_CA_FILE=""
RDS_CA=$BASE/rds-ca/rds-ca-bundle.pem
SWAP_BYTES=$((2048 * 1024 * 1024))
SKIP_UPGRADE=false SKIP_SWAP=false SKIP_CODEDEPLOY=false START=true

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die() {
  log "중단: $*"
  exit 1
}

usage() {
  sed -n '2,28p' "$0" >&2
  exit 2
}

parse_args() {
  while (($#)); do
    case $1 in
    --pipeline-ref)
      PIPELINE_REF=${2:-}
      shift 2
      ;;
    --raw-root)
      RAW_ROOT=${2:-}
      shift 2
      ;;
    --skip-upgrade)
      SKIP_UPGRADE=true
      shift
      ;;
    --skip-swap)
      SKIP_SWAP=true
      shift
      ;;
    --skip-codedeploy)
      SKIP_CODEDEPLOY=true
      shift
      ;;
    --no-start)
      START=false
      shift
      ;;
    --rds-ca-file)
      RDS_CA_FILE=${2:-}
      shift 2
      ;;
    *) usage ;;
    esac
  done
  [[ -n "$PIPELINE_REF" && -n "$RAW_ROOT" ]] || usage
  [[ "$RAW_ROOT" == */ ]] || RAW_ROOT="$RAW_ROOT/"
}

preflight() {
  [[ $EUID -eq 0 ]] || die "root로 실행한다(sudo bash ...)"
  [[ "$(uname -m)" == aarch64 ]] || log "경고: arm64가 아니다($(uname -m)). t4g 기준 스크립트"
  grep -q 'Amazon Linux' /etc/os-release || die "Amazon Linux 2023에서 실행한다"
}

step_upgrade() {
  $SKIP_UPGRADE && return
  log "1. dnf upgrade"
  dnf -y -q upgrade
}

step_swap() {
  if $SKIP_SWAP; then
    log "2. 스왑 건너뜀(--skip-swap)"
    return
  fi
  if swapon --show=NAME --noheadings | grep -qx /swapfile; then
    log "2. 스왑 있음: /swapfile"
    return
  fi
  log "2. 스왑 파일 2GB 만들기"
  # 이전 실행에서 dd가 중간에 끊겨 크기가 모자라면 새로 만든다
  if [[ ! -f /swapfile || "$(stat -c %s /swapfile)" -ne $SWAP_BYTES ]]; then
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >>/etc/fstab
}

step_packages() {
  log "3. 패키지 설치"
  dnf -y -q install python3.12 python3.12-pip postgresql16 git jq tar gzip awscli-2 procps-ng sudo
}

step_user_dirs() {
  log "4. 사용자·경로"
  getent group airflow >/dev/null || groupadd --system airflow
  id airflow >/dev/null 2>&1 ||
    useradd --system --gid airflow --create-home --shell /bin/bash airflow
  install -d -m 0755 -o root -g root "$BASE" "$BIN"
  install -d -m 0750 -o airflow -g airflow "$AIRFLOW_HOME" "$AIRFLOW_HOME/logs" "$STATE" "$STATE/runs"
  install -d -m 0755 -o airflow -g airflow "$PIPELINE_DIR" "$STATE/uv-cache"
  # 추출 임시 파일(architecture.md 4-3). 부팅 때 /tmp가 비워지므로 tmpfiles로 다시 만든다
  echo 'd /tmp/signal 0750 airflow airflow -' >/etc/tmpfiles.d/signal.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/signal.conf 2>/dev/null || install -d -m 0750 -o airflow -g airflow /tmp/signal
}

step_airflow() {
  local constraints="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-3.12.txt"
  if [[ -x "$AIRFLOW_VENV/bin/airflow" ]] &&
    [[ "$("$AIRFLOW_VENV/bin/pip" show apache-airflow 2>/dev/null | awk '/^Version:/{print $2}')" == "$AIRFLOW_VERSION" ]]; then
    log "5. Airflow $AIRFLOW_VERSION 있음"
    return
  fi
  log "5. Airflow $AIRFLOW_VERSION 설치(공식 제약 파일)"
  # 이전 실행이 venv 생성 중에 끊겨 pip가 없으면 venv를 새로 만든다
  [[ -x "$AIRFLOW_VENV/bin/pip" ]] || "$PYTHON" -m venv --clear "$AIRFLOW_VENV"
  "$AIRFLOW_VENV/bin/pip" install -q --upgrade pip
  "$AIRFLOW_VENV/bin/pip" install -q "apache-airflow[postgres,amazon]==${AIRFLOW_VERSION}" --constraint "$constraints"
}

step_uv() {
  local tar="uv-aarch64-unknown-linux-gnu.tar.gz" url tmp
  [[ "$(uname -m)" == aarch64 ]] || tar="uv-x86_64-unknown-linux-gnu.tar.gz"
  if [[ -x /usr/local/bin/uv ]] && [[ "$(/usr/local/bin/uv --version | awk '{print $2}')" == "$UV_VERSION" ]]; then
    log "6. uv $UV_VERSION 있음"
    return
  fi
  log "6. uv $UV_VERSION 설치(GitHub 릴리스, sha256 확인)"
  url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${tar}"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/$tar" "$url"
  curl -fsSL -o "$tmp/$tar.sha256" "$url.sha256"
  (cd "$tmp" && sha256sum -c "$tar.sha256" >/dev/null) || die "uv 내려받기 sha256 불일치"
  tar -xzf "$tmp/$tar" -C "$tmp"
  install -m 0755 "$tmp"/uv-*/uv "$tmp"/uv-*/uvx /usr/local/bin/
  rm -rf "$tmp"
}

step_pipeline() {
  log "6. signal-pipeline $PIPELINE_REF 받기와 uv.lock 그대로 설치"
  if [[ ! -d "$PIPELINE_DIR/.git" ]]; then
    sudo -u airflow git clone --quiet "$PIPELINE_REPO" "$PIPELINE_DIR"
  fi
  sudo -u airflow git -C "$PIPELINE_DIR" fetch --quiet --tags origin
  sudo -u airflow git -C "$PIPELINE_DIR" -c advice.detachedHead=false checkout --quiet "$PIPELINE_REF"
  if sudo -u airflow git -C "$PIPELINE_DIR" symbolic-ref -q HEAD >/dev/null; then
    sudo -u airflow git -C "$PIPELINE_DIR" pull --quiet --ff-only
  fi
  install -d -m 0755 -o airflow -g airflow "$PIPELINE_DIR/dags"
  (cd "$PIPELINE_DIR" && sudo -u airflow env UV_PYTHON="$PYTHON" UV_PYTHON_DOWNLOADS=never \
    UV_CACHE_DIR="$STATE/uv-cache" /usr/local/bin/uv sync --locked --no-dev --quiet)
}

step_rds_ca() {
  local url="https://truststore.pki.rds.amazonaws.com/${REGION}/${REGION}-bundle.pem"
  install -d -m 0755 "$(dirname "$RDS_CA")"
  if [[ -n "$RDS_CA_FILE" ]]; then
    log "7. RDS CA 묶음: $RDS_CA_FILE(--rds-ca-file)"
    install -m 0644 "$RDS_CA_FILE" "$RDS_CA"
  else
    log "7. RDS CA 묶음 받기($url)"
    curl -fsSL -o "$RDS_CA.tmp" "$url"
    grep -q 'BEGIN CERTIFICATE' "$RDS_CA.tmp" || die "RDS CA 묶음이 인증서 형식이 아니다: $url"
    install -m 0644 "$RDS_CA.tmp" "$RDS_CA"
    rm -f "$RDS_CA.tmp"
  fi
}

step_helpers() {
  log "7. SSM에서 비밀값을 읽는 명령"
  cat >"$BIN/ssm-get" <<'EOF'
#!/bin/bash
# SSM Parameter Store 값 하나를 표준 출력으로 낸다. Airflow _cmd 설정과 DAG 작업이 부른다
set -euo pipefail
exec aws --region "${AWS_DEFAULT_REGION:-ap-northeast-2}" ssm get-parameter --name "$1" \
  --with-decryption --query Parameter.Value --output text
EOF
  cat >"$BIN/airflow-sql-conn" <<EOF
#!/bin/bash
# Airflow 메타데이터 DB 연결 문자열(RDS airflow 데이터베이스, TLS와 서버 인증서 확인). 비밀번호는 실행 때 SSM에서 읽는다
set -euo pipefail
PW=\$($BIN/ssm-get /signal/rds/airflow_password) exec $AIRFLOW_VENV/bin/python -c '
import os, urllib.parse
pw = urllib.parse.quote(os.environ["PW"], safe="")
host = os.environ["SIGNAL_RDS_HOST"]
print(f"postgresql+psycopg2://airflow:{pw}@{host}:5432/airflow?sslmode=verify-full&sslrootcert=$RDS_CA")'
EOF
  chmod 0755 "$BIN/ssm-get" "$BIN/airflow-sql-conn"
}

step_config() {
  local host
  log "8. /etc/sysconfig/airflow와 systemd 서비스"
  host=$("$BIN/ssm-get" /signal/infra/rds_endpoint) || die "SSM /signal/infra/rds_endpoint를 읽지 못했다(03-rds.sh 먼저)"
  # 비밀이 아닌 값만 둔다. 비밀값은 *_CMD가 실행 때 SSM에서 읽는다.
  # 공백이 든 값은 큰따옴표로 감싼다(systemd EnvironmentFile과 bash source 모두 같은 값으로 읽음)
  cat >/etc/sysconfig/airflow <<EOF
AIRFLOW_HOME=$AIRFLOW_HOME
PATH=$AIRFLOW_VENV/bin:/usr/local/bin:/usr/bin:/bin
AWS_DEFAULT_REGION=$REGION
SIGNAL_RDS_HOST=$host
AIRFLOW__CORE__EXECUTOR=LocalExecutor
AIRFLOW__CORE__DAGS_FOLDER=$PIPELINE_DIR/dags
AIRFLOW__CORE__LOAD_EXAMPLES=False
AIRFLOW__CORE__PARALLELISM=2
AIRFLOW__CORE__MAX_ACTIVE_TASKS_PER_DAG=2
AIRFLOW__CORE__FERNET_KEY_CMD="$BIN/ssm-get /signal/airflow/fernet_key"
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN_CMD=$BIN/airflow-sql-conn
AIRFLOW__SCHEDULER__CATCHUP_BY_DEFAULT=False
AIRFLOW__SCHEDULER__PARSING_PROCESSES=1
AIRFLOW__WEBSERVER__WORKERS=1
AIRFLOW__WEBSERVER__WEB_SERVER_HOST=127.0.0.1
AIRFLOW__WEBSERVER__WEB_SERVER_PORT=8080
AIRFLOW__WEBSERVER__SECRET_KEY_CMD="$BIN/ssm-get /signal/airflow/webserver_secret_key"
RAW_ROOT=$RAW_ROOT
EXTRACT_WORKERS=2
UV_PYTHON=$PYTHON
UV_PYTHON_DOWNLOADS=never
UV_CACHE_DIR=$STATE/uv-cache
EOF
  chown root:airflow /etc/sysconfig/airflow
  chmod 0640 /etc/sysconfig/airflow

  # Airflow 공식 systemd 예시(Red Hat 계열, airflow:airflow, /etc/sysconfig/airflow) 기준
  cat >/etc/systemd/system/airflow-scheduler.service <<EOF
[Unit]
Description=Airflow scheduler (LocalExecutor)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/sysconfig/airflow
User=airflow
Group=airflow
Type=simple
ExecStart=$AIRFLOW_VENV/bin/airflow scheduler
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/airflow-webserver.service <<EOF
[Unit]
Description=Airflow webserver (127.0.0.1:8080, Session Manager 포트 전달로 접속)
After=network-online.target airflow-scheduler.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/sysconfig/airflow
User=airflow
Group=airflow
Type=simple
RuntimeDirectory=airflow
ExecStart=$AIRFLOW_VENV/bin/airflow webserver --pid /run/airflow/webserver.pid
Restart=always
RestartSec=5s
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

step_logs() {
  log "9. 로그 정리 타이머(14일)·journald 상한 200MB"
  cat >/etc/systemd/system/airflow-log-cleanup.service <<EOF
[Unit]
Description=Delete Airflow task logs older than 14 days

[Service]
Type=oneshot
User=airflow
ExecStart=/usr/bin/find $AIRFLOW_HOME/logs -type f -mtime +14 -delete
ExecStart=/usr/bin/find $AIRFLOW_HOME/logs -mindepth 1 -type d -empty -delete
EOF
  cat >/etc/systemd/system/airflow-log-cleanup.timer <<'EOF'
[Unit]
Description=Daily Airflow log cleanup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
  install -d /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=200M\n' >/etc/systemd/journald.conf.d/50-signal.conf
  systemctl daemon-reload
  systemctl restart systemd-journald
  systemctl enable --now airflow-log-cleanup.timer >/dev/null
}

step_codedeploy() {
  if $SKIP_CODEDEPLOY; then
    log "10. CodeDeploy 에이전트 건너뜀(--skip-codedeploy)"
    return
  fi
  # 이 서비스는 SysV 스크립트를 같이 둬서 enable에 chkconfig(systemd-sysv-install)가 필요하다
  dnf -y -q install chkconfig
  if rpm -q codedeploy-agent >/dev/null 2>&1; then
    log "10. CodeDeploy 에이전트 있음($(rpm -q codedeploy-agent))"
  else
    log "10. CodeDeploy 에이전트 설치(공식 설치 경로)"
    # 설치 프로그램은 which로 패키지 관리자를 찾는다(which가 없으면 「supported package managers」 오류)
    dnf -y -q install ruby wget which
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/install" "https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install"
    chmod +x "$tmp/install"
    "$tmp/install" auto >/dev/null
    rm -rf "$tmp"
  fi
  # 설치 프로그램은 서비스를 켜기만 하고 부팅 시 자동 시작은 켜지 않는다(Amazon Linux 2023 컨테이너에서 확인)
  systemctl enable --now codedeploy-agent >/dev/null
}

as_airflow() {
  # systemd 서비스와 같은 환경으로 airflow 명령을 실행한다
  sudo -u airflow bash -c 'set -a; source /etc/sysconfig/airflow; set +a; exec "$@"' _ "$@"
}

step_airflow_db() {
  local pw
  log "11. airflow db migrate, 관리자 계정, pool"
  as_airflow airflow db migrate >/dev/null
  # airflow CLI는 표준 출력에 로그 줄을 먼저 찍으므로 JSON 줄만 고른다. 사용자가 없으면 JSON 줄이 없다
  if ! as_airflow airflow users list -o json 2>/dev/null | { grep '^\[{' || true; } |
    jq -e -s 'any(.[][]; .username == "admin")' >/dev/null; then
    pw=$("$BIN/ssm-get" /signal/airflow/admin_password) || die "SSM /signal/airflow/admin_password가 없다"
    # 비밀번호를 명령 인자로 넘기지 않는다(sudo 로그·ps에 남음). --password 없이 실행하면 getpass로 두 번 묻는데,
    # setsid로 제어 터미널을 떼면 getpass가 표준 입력에서 읽는다. printf는 셸 내장이라 프로세스 목록에 남지 않는다
    printf '%s\n%s\n' "$pw" "$pw" | as_airflow setsid -w airflow users create --username admin --role Admin \
      --firstname signal --lastname admin --email admin@example.invalid >/dev/null ||
      die "관리자 계정을 만들지 못했다"
    unset pw
    as_airflow airflow users list -o json 2>/dev/null | grep '^\[{' | jq -e 'any(.[]; .username == "admin")' >/dev/null ||
      die "관리자 계정 admin이 목록에 없다"
    log "관리자 계정 admin 만듦(비밀번호는 SSM /signal/airflow/admin_password)"
  fi
  as_airflow airflow pools set signal_cpu 2 "signal DAG 공유 CPU 슬롯(architecture.md 2-3)" >/dev/null
}

step_start() {
  if ! $START; then
    log "서비스 시작 건너뜀(--no-start)"
    return
  fi
  systemctl daemon-reload
  systemctl enable airflow-scheduler airflow-webserver >/dev/null
  systemctl restart airflow-scheduler airflow-webserver
  local i
  for i in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
      log "웹 서버 응답 확인(127.0.0.1:8080/health, ${i}회째)"
      return
    fi
    sleep 5
  done
  die "웹 서버가 5분 안에 응답하지 않았다. journalctl -u airflow-webserver로 확인한다"
}

step_report() {
  local report=$STATE/setup-report.txt
  {
    echo "기록 시각(UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # shellcheck disable=SC1091
    echo "OS: $(. /etc/os-release && echo "$PRETTY_NAME"), 커널 $(uname -r), $(uname -m)"
    echo "Python: $($PYTHON --version)"
    echo "Airflow: $("$AIRFLOW_VENV/bin/pip" show apache-airflow | awk '/^Version:/{print $2}')"
    echo "uv: $(/usr/local/bin/uv --version)"
    echo "signal-pipeline: $PIPELINE_REF ($(sudo -u airflow git -C "$PIPELINE_DIR" rev-parse --short HEAD))"
    echo "pdfplumber: $("$PIPELINE_DIR/.venv/bin/python" -c 'import pdfplumber; print(pdfplumber.__version__)' 2>/dev/null || echo n/a)"
    echo "pg_dump: $(pg_dump --version)"
    echo "스왑: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
    echo "디스크(/): $(df -h / | awk 'NR==2{print $3 " 사용 / " $2}')"
    echo "메모리: $(free -m | awk 'NR==2{print $3 "MB 사용 / " $2 "MB"}')"
  } >"$report"
  cat "$report" >&2
}

main() {
  parse_args "$@"
  preflight
  step_upgrade
  step_swap
  step_packages
  step_user_dirs
  step_airflow
  step_uv
  step_pipeline
  step_rds_ca
  step_helpers
  step_config
  step_logs
  step_codedeploy
  step_airflow_db
  step_start
  step_report
  log "10 완료. 화면 접속: aws ssm start-session --target <인스턴스 ID> --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080"
}

main "$@"
