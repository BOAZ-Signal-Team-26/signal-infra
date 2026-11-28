#!/usr/bin/env bash
# 00~05 스크립트를 모의 AWS(moto 서버, Docker 컨테이너)에 두 번 실행한다. 실제 AWS에는 접속하지 않는다.
#
# 확인하는 것
# - 스크립트가 끝까지 도는지(명령·인자 형식)
# - 두 번째 실행에서 자원이 늘지 않는지(다시 실행해도 됨)
# - 이름·태그·주요 설정이 결정값과 같은지
# 확인하지 못하는 것(moto가 흉내 내지 않음): 버킷 정책의 실제 거부 동작, 계정 리전 네임스페이스 이름 규칙,
#   RDS 엔진 버전·Database Insights 값 검증, Budgets 동작 실행. 이것은 구축 뒤 6절 12 확인 항목으로 본다
#
# 사용: scripts/aws/local-test/moto-test.sh   (Docker 필요. 끝나면 컨테이너를 지움)

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AWS_DIR=$(dirname "$HERE")
PORT="${MOTO_PORT:-5055}"
NAME=signal-moto-test

docker rm -f "$NAME" >/dev/null 2>&1 || true
# AWS 관리형 정책(AmazonSSMManagedInstanceCore 등)을 모의 서버에 미리 올린다
docker run -d --name "$NAME" -p "$PORT:5000" -e MOTO_IAM_LOAD_MANAGED_POLICIES=true motoserver/moto:latest >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

# 모든 AWS CLI 호출을 모의 서버로 보낸다. 사용자 설정·자격 증명 파일을 읽지 않는다
export AWS_ENDPOINT_URL="http://localhost:$PORT"
export AWS_ACCESS_KEY_ID=testing AWS_SECRET_ACCESS_KEY=testing
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
unset AWS_PROFILE AWS_SESSION_TOKEN

for _ in $(seq 1 30); do
  aws sts get-caller-identity >/dev/null 2>&1 && break
  sleep 1
done
account=$(aws sts get-caller-identity --query Account --output text)
[[ "$account" == "123456789012" ]] || {
  echo "모의 서버가 아닌 계정($account)에 연결됐다. 중단" >&2
  exit 1
}

# 계정 준비(6절 1, PM 몫)를 흉내 낸다: 그룹 signal-team, 예산 monthly-50usd
aws iam create-group --group-name signal-team >/dev/null
aws iam create-user --user-name test-admin >/dev/null
make_budget() {
  aws budgets create-budget --account-id "$account" --budget \
    "BudgetName=monthly-50usd,BudgetLimit={Amount=50,Unit=USD},TimeUnit=MONTHLY,BudgetType=COST,CostTypes={IncludeCredit=$1}" >/dev/null
}
# 크레딧을 포함해 집계하는 예산이면 05가 멈춰야 한다. 확인 뒤 크레딧 제외 예산으로 바꾼다
make_budget true

"$AWS_DIR/00-put-secret.sh" /signal/rds/master_password --generate password
"$AWS_DIR/00-put-secret.sh" /signal/rds/master_password --generate password # 두 번째는 건너뜀

run_all() {
  "$AWS_DIR/01-network.sh"
  "$AWS_DIR/02-s3.sh"
  "$AWS_DIR/03-rds.sh"
  PROTECT_EIP_USERS=test-admin "$AWS_DIR/04-ec2.sh"
  if BUDGET_EMAILS="a@example.com b@example.com" "$AWS_DIR/05-budgets.sh"; then
    echo "05: 통과"
  else
    echo "05: 실패(moto가 Budgets 동작 API를 지원하지 않으면 실패함. 아래 출력 확인)"
  fi
  "$AWS_DIR/06-team-guardrails.sh"
}

echo "===== 05: 크레딧 포함 예산이면 멈춤"
budget_credit_check=fail
if out=$(BUDGET_EMAILS="a@example.com" "$AWS_DIR/05-budgets.sh" 2>&1); then
  echo "05가 멈추지 않았다"
elif [[ "$out" == *"크레딧을 포함해 집계한다"* ]]; then
  budget_credit_check=ok
else
  echo "$out" | tail -3
fi
aws budgets delete-budget --account-id "$account" --budget-name monthly-50usd
make_budget false

echo "===== 1회차"
run_all
# 탄력적 IP를 새로 받은 상황을 흉내 낸다: signal-protect-eip 기본 버전을 다른 할당 ID로 바꿔 두고 2회차에서 되돌아오는지 본다
protect_arn="arn:aws:iam::$account:policy/signal-protect-eip"
aws iam create-policy-version --policy-arn "$protect_arn" --set-as-default \
  --policy-document "$(sed "s/{{REGION}}/ap-northeast-2/; s/{{ACCOUNT_ID}}/$account/; s/{{ALLOCATION_ID}}/eipalloc-old/" "$AWS_DIR/policies/protect-eip.json")" >/dev/null
echo "===== 2회차(다시 실행)"
run_all

echo "===== 자원 수(태그 Project=signal)"
f="Name=tag:Project,Values=signal"
check() {
  local what=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    printf '  ok   %-28s %s\n' "$what" "$got"
  else
    printf '  FAIL %-28s %s (기대 %s)\n' "$what" "$got" "$want"
    failed=1
  fi
}
failed=0
check VPC "$(aws ec2 describe-vpcs --filters "$f" --query 'length(Vpcs)')" 1
check 서브넷 "$(aws ec2 describe-subnets --filters "$f" --query 'length(Subnets)')" 3
check 공인IP자동할당 "$(aws ec2 describe-subnets --filters "$f" --query 'length(Subnets[?MapPublicIpOnLaunch])')" 0
check 인터넷게이트웨이 "$(aws ec2 describe-internet-gateways --filters "$f" --query 'length(InternetGateways)')" 1
check 라우팅표 "$(aws ec2 describe-route-tables --filters "$f" --query 'length(RouteTables)')" 2
check S3엔드포인트 "$(aws ec2 describe-vpc-endpoints --filters "$f" --query 'length(VpcEndpoints)')" 1
check 보안그룹 "$(aws ec2 describe-security-groups --filters "$f" --query 'length(SecurityGroups)')" 2
check EC2보안그룹_인바운드 "$(aws ec2 describe-security-groups --filters "$f" Name=group-name,Values=signal-ec2-sg --query 'length(SecurityGroups[0].IpPermissions)')" 0
check RDS보안그룹_인바운드 "$(aws ec2 describe-security-groups --filters "$f" Name=group-name,Values=signal-rds-sg --query 'SecurityGroups[0].IpPermissions[0].[FromPort,length(UserIdGroupPairs)]' --output text | tr '\t' ' ')" "5432 1"
check 탄력적IP "$(aws ec2 describe-addresses --filters "$f" --query 'length(Addresses)')" 1
check EC2 "$(aws ec2 describe-instances --filters "$f" --query 'length(Reservations[].Instances[])')" 1
check EC2_종류 "$(aws ec2 describe-instances --filters "$f" --query 'Reservations[0].Instances[0].InstanceType' --output text)" t4g.small
check EC2_IMDSv2 "$(aws ec2 describe-instances --filters "$f" --query 'Reservations[0].Instances[0].MetadataOptions.[HttpTokens,HttpPutResponseHopLimit]' --output text | tr '\t' ' ')" "required 1"
check 탄력적IP_연결 "$(aws ec2 describe-addresses --filters "$f" --query 'Addresses[0].InstanceId!=null')" true
check RDS "$(aws rds describe-db-instances --query 'length(DBInstances)')" 1
check RDS_설정 "$(aws rds describe-db-instances --query 'DBInstances[0].[EngineVersion,DBInstanceClass,MultiAZ,PubliclyAccessible,StorageEncrypted,DeletionProtection,BackupRetentionPeriod]' --output text | tr '\t' ' ')" "16.15 db.t4g.micro False False True True 7"
bucket="signal-data-$account-ap-northeast-2-an"
check 버킷 "$(aws s3api list-buckets --query "length(Buckets[?Name=='$bucket'])")" 1
check 버전관리 "$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text)" Enabled
check 공개차단 "$(aws s3api get-public-access-block --bucket "$bucket" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' --output text | tr '\t' ' ')" "True True True True"
check 수명주기_규칙수 "$(aws s3api get-bucket-lifecycle-configuration --bucket "$bucket" --query 'length(Rules)')" 9
check 버킷정책_문장수 "$(aws s3api get-bucket-policy --bucket "$bucket" --query Policy --output text | jq '.Statement | length')" 4
check 버킷정책_TLS거부 "$(aws s3api get-bucket-policy --bucket "$bucket" --query Policy --output text | jq -r '.Statement[] | select(.Sid=="DenyInsecureTransport") | .Condition.Bool["aws:SecureTransport"]')" false
check EC2역할_DB비밀번호거부 "$(aws iam get-role-policy --role-name signal-pipeline-ec2 --policy-name signal-pipeline-ec2-access --query PolicyDocument --output json | jq -r '[.Statement[] | select(.Effect=="Deny") | .Resource[] | split("/") | last] | join(" ")')" "master_password owner_password reader_password"
check EC2역할_경로조회없음 "$(aws iam get-role-policy --role-name signal-pipeline-ec2 --policy-name signal-pipeline-ec2-access --query PolicyDocument --output json | jq '[.. | strings | select(. == "ssm:GetParametersByPath")] | length')" 0
check EIP보호정책_할당ID갱신 "$(aws iam get-policy-version --policy-arn "$protect_arn" --version-id "$(aws iam get-policy --policy-arn "$protect_arn" --query Policy.DefaultVersionId --output text)" --query PolicyVersion.Document --output json | jq -r '.. | strings | select(startswith("arn:aws:ec2")) | split("/") | last')" "$(aws ec2 describe-addresses --filters "$f" --query 'Addresses[0].AllocationId' --output text)"
check 예산_크레딧포함이면멈춤 "$budget_credit_check" ok
check EC2역할_deploy읽기만 "$(aws iam get-role-policy --role-name signal-pipeline-ec2 --policy-name signal-pipeline-ec2-access --query PolicyDocument --output json | jq -r '[.Statement[] | select(.Effect=="Allow") | select([.Resource] | flatten | any(test("/deploy/"))) | [.Action] | flatten | join(",")] | join(" ")')" "s3:GetObject"
guard_arn="arn:aws:iam::$account:policy/signal-team-guardrails"
check 팀보호정책_연결 "$(aws iam list-entities-for-policy --policy-arn "$guard_arn" --query '[length(PolicyGroups),length(PolicyUsers),PolicyGroups[0].GroupName]' --output text | tr '\t' ' ')" "1 0 signal-team"
guard_doc=$(aws iam get-policy-version --policy-arn "$guard_arn" --version-id "$(aws iam get-policy --policy-arn "$guard_arn" --query Policy.DefaultVersionId --output text)" --query PolicyVersion.Document --output json)
check 팀보호정책_거부동작 "$(jq -r '[.Statement[] | select(.Effect=="Deny") | [.Action] | flatten | length] | add' <<<"$guard_doc")" 26
# 문장 하나의 "Effect Action,... Resource,..."
guard_stmt() { jq -r --arg sid "$1" '.Statement[] | select(.Sid==$sid) | "\(.Effect) \([.Action] | flatten | join(",")) \([.Resource] | flatten | join(","))"' <<<"$guard_doc"; }
check 팀보호정책_경로조회 "$(guard_stmt DenyParametersByPath)" "Deny ssm:GetParametersByPath *"
check 팀보호정책_deploy쓰기 "$(guard_stmt DenyDeployBundleWrites)" "Deny s3:PutObject,s3:DeleteObject,s3:DeleteObjectVersion arn:aws:s3:::$bucket/deploy/*"
check 팀보호정책_CodeDeploy "$(guard_stmt DenyCodeDeployChanges)" "Deny codedeploy:Create*,codedeploy:Update*,codedeploy:Delete*,codedeploy:Put*,codedeploy:Register*,codedeploy:Deregister*,codedeploy:Add*,codedeploy:Remove*,codedeploy:TagResource,codedeploy:UntagResource,codedeploy:Stop*,codedeploy:Continue*,codedeploy:Skip* *"
check 팀보호정책_버전수 "$(aws iam list-policy-versions --policy-arn "$guard_arn" --query 'length(Versions)')" 1
check 역할 "$(aws iam list-roles --query "length(Roles[?starts_with(RoleName, 'signal-')])")" 2
check EIP보호정책_연결 "$(aws iam list-entities-for-policy --policy-arn "arn:aws:iam::$account:policy/signal-protect-eip" --query '[length(PolicyGroups),length(PolicyUsers)]' --output text | tr '\t' ' ')" "1 1"
# shellcheck disable=SC2016 # 백틱은 JMESPath 숫자 표기
check SSM_RDS엔드포인트 "$(aws ssm get-parameter --name /signal/infra/rds_endpoint --query 'length(Parameter.Value) > `0`')" true
# shellcheck disable=SC2016
check SSM_공인IP "$(aws ssm get-parameter --name /signal/infra/eip_public_ip --query 'length(Parameter.Value) > `0`')" true
# moto는 Budgets 동작 API(DescribeBudgetActionsForBudget·CreateBudgetAction)를 구현하지 않아 500을 낸다.
# 05는 요청 형식(필수 인자·자료형, AWS CLI가 보내기 전에 검사)까지만 확인되고, 실제 동작은 구축 뒤 BUDGET_THRESHOLD를 낮춰 시험한다
printf '  skip %-28s %s\n' 예산동작 "모의 서버 미지원(구축 뒤 6절 12에서 시험)"
exit "$failed"
