#!/usr/bin/env bash
# 10-ec2-setup.sh 리허설과 Airflow 메모리 측정(storage-design.md 3.3 합격 기준).
#
# EC2 대신 Amazon Linux 2023 arm64 컨테이너(systemd, 메모리 2GB·CPU 2개 제한)에서 10-ec2-setup.sh를 그대로 실행하고,
# 유휴 상태와 추출 병렬 2로 DART PDF N건(기본 50)을 처리하는 동안의 메모리를 1초 간격으로 기록한다.
# 실제 AWS에는 접속하지 않는다: SSM Parameter Store는 moto 컨테이너, RDS는 TLS 필수로 띄운 PostgreSQL 16 컨테이너.
# 인터넷에서 받는 것: dnf 패키지, Airflow·uv·signal-pipeline 의존성, signal-pipeline 공개 저장소, CodeDeploy 설치 파일.
#
# EC2와 다른 점(결과를 읽을 때 감안)
# - 사용 메모리는 cgroup anon + kernel(프로세스 메모리와 그 프로세스가 쓴 커널 메모리). cgroup에 잡히지 않는
#   커널 공용 메모리와 컨테이너에 없는 OS 기본 프로세스(chronyd 등)는 빠진다. EC2에서는 이만큼 더 쓴다
# - 스왑은 Docker VM 스왑(1GB)을 쓴다. EC2는 스왑 파일 2GB
# - CPU 2개 제한은 CFS quota라 t4g.small의 CPU 크레딧(기준 성능 20%)은 흉내 내지 않는다. 처리 시간은 참고값
#
# 사용: scripts/aws/local-test/ec2-sim.sh --raw-dir <RAW_ROOT 경로(raw/dart 포함)> [--files 50] [--idle 180]
#       [--pipeline-ref dev] [--skip-codedeploy] [--rerun] [--keep] [--out <결과 폴더>]
# --rerun: 10-ec2-setup.sh를 한 번 더 실행해 다시 실행해도 되는지 본다(스왑 단계는 컨테이너라 건너뜀)
# RDS 연결은 10번과 같이 sslmode=verify-full이다. 모의 RDS의 자체 서명 인증서를 --rds-ca-file로 넘긴다

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AWS_DIR=$(dirname "$HERE")
NET=signal-ec2sim MOTO=ec2sim-moto RDS=ec2sim-rds HOST=ec2sim-host
MOTO_PORT="${MOTO_PORT:-5057}"
FILES=50 IDLE=180 PIPELINE_REF=dev SETUP_FLAGS=(--skip-swap --rds-ca-file /root/rds-ca.pem) KEEP=false RERUN=false RAW_DIR="" OUT=""

while (($#)); do
  case $1 in
  --raw-dir) RAW_DIR=$2; shift 2 ;;
  --files) FILES=$2; shift 2 ;;
  --idle) IDLE=$2; shift 2 ;;
  --pipeline-ref) PIPELINE_REF=$2; shift 2 ;;
  --skip-codedeploy) SETUP_FLAGS+=(--skip-codedeploy); shift ;;
  --rerun) RERUN=true; shift ;;
  --keep) KEEP=true; shift ;;
  --out) OUT=$2; shift 2 ;;
  *) sed -n '2,18p' "$0" >&2; exit 2 ;;
  esac
done
[[ -d "$RAW_DIR/raw/dart" ]] || { echo "--raw-dir 아래 raw/dart가 없다" >&2; exit 2; }
OUT=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/ec2-sim.XXXXXX")}
mkdir -p "$OUT"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$OUT/harness.log" >&2; }

cleanup() {
  if ! $KEEP; then docker rm -f "$HOST" "$RDS" "$MOTO" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
docker rm -f "$HOST" "$RDS" "$MOTO" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null 2>&1 || true

log "모의 SSM(moto) 시작"
docker run -d --name "$MOTO" --network "$NET" -p "$MOTO_PORT:5000" motoserver/moto:latest >/dev/null
moto_env=(env AWS_ENDPOINT_URL="http://localhost:$MOTO_PORT" AWS_ACCESS_KEY_ID=testing AWS_SECRET_ACCESS_KEY=testing
  AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2)
for _ in $(seq 1 30); do "${moto_env[@]}" aws sts get-caller-identity >/dev/null 2>&1 && break; sleep 1; done
[[ "$("${moto_env[@]}" aws sts get-caller-identity --query Account --output text)" == 123456789012 ]] || {
  log "moto가 아닌 곳에 연결됨. 중단"; exit 1; }
for name in /signal/rds/airflow_password /signal/airflow/admin_password /signal/airflow/webserver_secret_key; do
  "${moto_env[@]}" "$AWS_DIR/00-put-secret.sh" "$name" --generate password
done
"${moto_env[@]}" "$AWS_DIR/00-put-secret.sh" /signal/airflow/fernet_key --generate fernet
"${moto_env[@]}" aws ssm put-parameter --name /signal/infra/rds_endpoint --type String --value "$RDS" --overwrite >/dev/null

log "모의 RDS(PostgreSQL 16, TLS 필수) 시작"
docker run -d --name "$RDS" --network "$NET" -e POSTGRES_PASSWORD=master-not-secret \
  --entrypoint bash postgres:16 -c '
    set -e
    d=/var/lib/postgresql/tls; mkdir -p $d
    openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj /CN=ec2sim-rds -keyout $d/server.key -out $d/server.crt 2>/dev/null
    chown -R postgres:postgres $d; chmod 600 $d/server.key
    mkdir -p /docker-entrypoint-initdb.d
    printf "%s\n" "sed -i \"s/^host all all all/hostssl all all all/\" \"\$PGDATA/pg_hba.conf\"" > /docker-entrypoint-initdb.d/10-hostssl.sh
    exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=$d/server.crt -c ssl_key_file=$d/server.key' >/dev/null
for _ in $(seq 1 60); do docker exec "$RDS" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
sleep 3
# PM 담당인 DB 계정 만들기를 흉내 낸다: airflow 계정과 airflow 데이터베이스
"${moto_env[@]}" aws ssm get-parameter --name /signal/rds/airflow_password --with-decryption \
  --query Parameter.Value --output text |
  docker exec -i "$RDS" bash -c 'read -r pw; psql -q -U postgres -v pw="$pw" <<SQL
create role airflow login password :'"'"'pw'"'"';
create database airflow owner airflow;
SQL'
docker exec "$RDS" grep -c '^hostssl' /var/lib/postgresql/data/pg_hba.conf | grep -q '^[1-9]' || {
  log "pg_hba가 TLS 필수로 바뀌지 않았다"; exit 1; }

log "EC2 흉내 컨테이너(Amazon Linux 2023 arm64, systemd, 메모리 2GB, CPU 2) 시작"
docker build -q -t signal-ec2sim:al2023 -f "$HERE/Dockerfile.al2023-systemd" "$HERE" >/dev/null
docker run -d --name "$HOST" --hostname "$HOST" --network "$NET" --privileged --cgroupns=private \
  --tmpfs /run --tmpfs /run/lock --memory 2g --memory-swap 3g --cpus 2 signal-ec2sim:al2023 >/dev/null
sleep 5
# 모의 SSM 주소와 시험용 자격 증명을 root·airflow 사용자의 AWS CLI 설정에 둔다(EC2에서는 인스턴스 역할이 이 역할)
docker exec "$HOST" bash -c '
  set -e
  getent group airflow >/dev/null || groupadd --system airflow
  id airflow >/dev/null 2>&1 || useradd --system --gid airflow --create-home --shell /bin/bash airflow
  for h in /root /home/airflow; do
    mkdir -p $h/.aws
    printf "[default]\nregion = ap-northeast-2\nendpoint_url = http://ec2sim-moto:5000\n" > $h/.aws/config
    printf "[default]\naws_access_key_id = testing\naws_secret_access_key = testing\n" > $h/.aws/credentials
  done
  chown -R airflow:airflow /home/airflow/.aws'
docker cp "$AWS_DIR" "$HOST:/root/signal-infra-aws"
# 모의 RDS의 자체 서명 인증서(CN=ec2sim-rds)를 CA 묶음으로 넘긴다(EC2에서는 RDS 공식 CA 묶음)
docker cp "$RDS:/var/lib/postgresql/tls/server.crt" "$OUT/rds-ca.pem"
docker cp "$OUT/rds-ca.pem" "$HOST:/root/rds-ca.pem"

log "10-ec2-setup.sh 실행(--pipeline-ref $PIPELINE_REF ${SETUP_FLAGS[*]})"
setup_start=$(date +%s)
docker exec "$HOST" bash /root/signal-infra-aws/10-ec2-setup.sh --pipeline-ref "$PIPELINE_REF" \
  --raw-root /var/lib/signal/data/ "${SETUP_FLAGS[@]}" 2>&1 | tee "$OUT/setup.log"
log "설정 끝: $(($(date +%s) - setup_start))초"
if $RERUN; then
  log "10-ec2-setup.sh 다시 실행(--rerun)"
  rerun_start=$(date +%s)
  docker exec "$HOST" bash /root/signal-infra-aws/10-ec2-setup.sh --pipeline-ref "$PIPELINE_REF" \
    --raw-root /var/lib/signal/data/ --skip-upgrade "${SETUP_FLAGS[@]}" 2>&1 | tee "$OUT/setup-rerun.log"
  log "다시 실행 끝: $(($(date +%s) - rerun_start))초"
fi
# 메타데이터 DB 연결이 verify-full인지 확인한다
docker exec "$HOST" sudo -u airflow bash -c 'set -a; source /etc/sysconfig/airflow; set +a; exec /opt/signal/bin/airflow-sql-conn' |
  grep -o 'sslmode=[a-z-]*' | tee "$OUT/sslmode.txt" >&2

log "원본 PDF ${FILES}건 복사(접수번호 폴더 단위)"
stage=$(mktemp -d)
mkdir -p "$stage/raw/dart"
find "$RAW_DIR/raw/dart" -mindepth 1 -maxdepth 1 -type d | sort | head -n "$FILES" |
  while read -r d; do cp -R "$d" "$stage/raw/dart/"; done
docker exec "$HOST" install -d -m 0750 -o airflow -g airflow /var/lib/signal/data
docker cp "$stage/raw" "$HOST:/var/lib/signal/data/"
docker exec "$HOST" chown -R airflow:airflow /var/lib/signal/data
docker cp "$HERE/dags/signal_smoke_extract.py" "$HOST:/opt/signal/signal-pipeline/dags/"
docker cp "$HERE/sample-memory.sh" "$HOST:/usr/local/bin/sample-memory.sh"
docker exec "$HOST" chown airflow:airflow /opt/signal/signal-pipeline/dags/signal_smoke_extract.py

as_airflow() {
  docker exec "$HOST" sudo -u airflow bash -c 'set -a; source /etc/sysconfig/airflow; set +a; exec "$@"' _ "$@"
}
as_airflow airflow dags reserialize >/dev/null 2>&1 || true
as_airflow airflow dags unpause signal_smoke_extract >/dev/null

# 설치 직후에는 dnf·pip 캐시가 컨테이너 메모리 한도를 채워 유휴 구간에도 스왑이 생긴다. 부팅 직후와 비슷하게
# 캐시를 비우고 상주 서비스를 다시 띄운 뒤 잰다(11월 13일 첫 측정에서 확인)
docker exec "$HOST" bash -c 'sync; echo 3 > /proc/sys/vm/drop_caches; systemctl restart airflow-scheduler airflow-webserver; systemctl try-restart codedeploy-agent'
sleep 60
log "유휴 측정 ${IDLE}초(웹 서버·스케줄러만, DAG 실행 없음)"
docker exec "$HOST" bash -c 'echo idle > /run/sample-memory.phase'
docker exec -d "$HOST" /usr/local/bin/sample-memory.sh /var/lib/signal/memory.csv
docker exec "$HOST" bash -c 'ps -eo rss,pss_kb=,comm,args --sort=-rss 2>/dev/null | head -25 || ps -eo rss,comm,args --sort=-rss | head -25' >"$OUT/ps-before.txt" 2>&1 || true
sleep "$IDLE"
docker exec "$HOST" bash -c 'ps -eo pid,rss,comm,args --sort=-rss | head -30' >"$OUT/ps-idle.txt"

log "추출 DAG 실행(병렬 2, ${FILES}건)"
docker exec "$HOST" bash -c 'echo extract > /run/sample-memory.phase'
as_airflow airflow dags trigger signal_smoke_extract --conf "{\"limit\": $FILES}" >/dev/null
state=""
for _ in $(seq 1 1080); do
  # airflow CLI는 표준 출력에 로그 줄을 먼저 찍으므로 JSON 줄만 고른다
  state=$(as_airflow airflow dags list-runs -d signal_smoke_extract -o json 2>/dev/null | grep '^\[{' | tail -1 |
    python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["state"] if r else "")' 2>/dev/null || true)
  [[ "$state" == success || "$state" == failed ]] && break
  sleep 5
done
log "DAG 실행 상태: ${state:-알 수 없음}"
docker exec "$HOST" bash -c 'echo after > /run/sample-memory.phase'
sleep 20
docker exec "$HOST" touch /run/sample-memory.stop
sleep 2

log "결과 모으기"
docker cp "$HOST:/var/lib/signal/memory.csv" "$OUT/memory.csv"
docker cp "$HOST:/var/lib/signal/setup-report.txt" "$OUT/setup-report.txt"
docker exec "$HOST" bash -c 'cat /var/lib/signal/data/runs/*/extraction_attempts.jsonl' >"$OUT/extraction_attempts.jsonl" || true
docker exec "$HOST" bash -c 'cat /var/lib/signal/data/runs/*/run.json' >"$OUT/run.json" || true
docker exec "$HOST" bash -c 'find /opt/signal/airflow/logs -name "*.log" -path "*signal_smoke_extract*" -exec tail -n 40 {} +' >"$OUT/task-log-tail.txt" || true
docker exec "$HOST" bash -c 'systemctl is-active airflow-scheduler airflow-webserver codedeploy-agent amazon-ssm-agent airflow-log-cleanup.timer; free -m; swapon --show; df -h /' >"$OUT/host-state.txt" 2>&1 || true
docker exec "$HOST" bash -c 'journalctl -u airflow-scheduler -u airflow-webserver --no-pager -n 80' >"$OUT/journal-tail.txt" 2>&1 || true
python3 "$HERE/summarize.py" "$OUT" | tee "$OUT/summary.md"
log "결과 폴더: $OUT"
