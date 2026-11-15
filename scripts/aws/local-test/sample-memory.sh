#!/usr/bin/env bash
# 리허설 컨테이너 안에서 1초마다 cgroup 메모리를 CSV로 남긴다. 멈추려면 /run/sample-memory.stop 파일을 만든다.
# 칼럼: 시각, 단계 표시(/run/sample-memory.phase 내용), 컨테이너 전체(current·anon·file·kernel·swap),
#       서비스별 anon(스케줄러, 웹 서버, CodeDeploy 에이전트, SSM 에이전트), 작업 프로세스 anon(스케줄러 cgroup에 포함)
set -euo pipefail
out=${1:-/var/lib/signal/memory.csv}
cg=/sys/fs/cgroup
stat() { awk -v k="$2" '$1==k{print $2}' "$1/memory.stat" 2>/dev/null || echo 0; }
svc() {
  local d=$cg/system.slice/$1.service
  if [[ -d "$d" ]]; then stat "$d" anon; else echo 0; fi
}
echo "ts,phase,current,anon,file,kernel,swap,scheduler_anon,webserver_anon,codedeploy_anon,ssm_agent_anon" >"$out"
rm -f /run/sample-memory.stop
while [[ ! -e /run/sample-memory.stop ]]; do
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%s)" "$(cat /run/sample-memory.phase 2>/dev/null || echo -)" \
    "$(cat $cg/memory.current)" "$(stat $cg anon)" "$(stat $cg file)" "$(stat $cg kernel)" \
    "$(cat $cg/memory.swap.current 2>/dev/null || echo 0)" \
    "$(svc airflow-scheduler)" "$(svc airflow-webserver)" "$(svc codedeploy-agent)" "$(svc amazon-ssm-agent)" >>"$out"
  sleep 1
done
