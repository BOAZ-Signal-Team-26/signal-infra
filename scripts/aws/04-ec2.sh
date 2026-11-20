#!/usr/bin/env bash
# 6절 6: EC2 인스턴스 역할, 탄력적 IP(해제 거부 정책)와 연결, EC2 t4g.small
#
# 값(11월 8일 결정)
# - 역할·인스턴스 프로필 signal-pipeline-ec2: AmazonSSMManagedInstanceCore + 버킷 읽기·쓰기(eval/ 제외) + SSM /signal/* 읽기.
#   EC2가 쓰지 않는 DB 비밀번호(master·owner·reader)는 명시적으로 거부한다. AmazonSSMManagedInstanceCore가
#   ssm:GetParameter(s)를 모든 자원에 허용하므로 Allow 범위를 좁히는 것만으로는 막히지 않는다(11월 15일 PR #35 리뷰)
# - 탄력적 IP signal-eip. 할당과 연결을 나눔. IAM 정책 signal-protect-eip로 이 IP의 해제(ec2:ReleaseAddress)를 거부하고
#   그룹 signal-team과 관리자 사용자에 붙인다. 사용자 이름은 저장소에 적지 않고 PROTECT_EIP_USERS로 받는다.
#   정책이 이미 있고 할당 ID가 바뀌었으면 새 정책 버전을 기본으로 만든다(버전이 5개면 가장 오래된 것을 지움)
# - 공인 IP는 SSM /signal/infra/eip_public_ip(String)에 적는다. 저장소에는 적지 않는다
# - EC2 signal-airflow: Amazon Linux 2023 표준 arm64(SSM 공개 파라미터로 최신 AMI), t4g.small, 공개 서브넷 2a,
#   signal-ec2-sg, gp3 20GB, IMDSv2 필수·홉 제한 1, SSH 키 없음, user data 없음
# - 11월 13일 결정: 루트 볼륨 암호화 켬(aws/ebs, 요금 없음),
#   CPU 크레딧 standard(크레딧이 바닥나도 추가 요금 없이 기준 성능으로 느려짐. 기본값 unlimited는 초과분 요금)
#
# 사용: PROTECT_EIP_USERS="<관리자 IAM 사용자> <관리자 IAM 사용자>" scripts/aws/04-ec2.sh   (01·02 뒤. 다시 실행해도 됨)

source "$(dirname "$0")/lib.sh"
require aws jq

ROLE=signal-pipeline-ec2
AMI_PARAM="${AMI_PARAM:-/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64}"

ensure_role() {
  if role_exists "$ROLE"; then
    log "역할 있음: $ROLE"
  else
    # shellcheck disable=SC2046
    aws iam create-role --role-name "$ROLE" \
      --assume-role-policy-document "file://$POLICY_DIR/ec2-trust.json" \
      --description "signal EC2 (Airflow) instance role" --tags $(tags_kv "$ROLE") >/dev/null
    log "역할 만듦: $ROLE"
  fi
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam put-role-policy --role-name "$ROLE" --policy-name signal-pipeline-ec2-access \
    --policy-document "$(render "$POLICY_DIR/ec2-access.json" "BUCKET=$(bucket_name)" \
      "REGION=$AWS_REGION" "ACCOUNT_ID=$(account_id)")"
  if ! aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    aws iam create-instance-profile --instance-profile-name "$ROLE" --tags $(tags_kv "$ROLE") >/dev/null
    aws iam wait instance-profile-exists --instance-profile-name "$ROLE"
    log "인스턴스 프로필 만듦: $ROLE"
  fi
  local roles
  roles=$(aws iam get-instance-profile --instance-profile-name "$ROLE" \
    --query 'InstanceProfile.Roles[].RoleName' --output text)
  if [[ " $roles " != *" $ROLE "* ]]; then
    aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
    log "인스턴스 프로필에 역할 넣음"
  fi
}

ensure_eip() {
  local id
  id=$(eip_allocation_id)
  if [[ -z "$id" ]]; then
    id=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "$(tag_spec elastic-ip signal-eip)" \
      --query AllocationId --output text)
    log "탄력적 IP 할당: signal-eip $id"
  else
    log "탄력적 IP 있음: signal-eip $id"
  fi
  printf '%s' "$id"
}

ensure_protect_policy() {
  local alloc=$1 arn doc user
  arn="arn:aws:iam::$(account_id):policy/signal-protect-eip"
  doc=$(render "$POLICY_DIR/protect-eip.json" "REGION=$AWS_REGION" \
    "ACCOUNT_ID=$(account_id)" "ALLOCATION_ID=$alloc")
  ensure_managed_policy signal-protect-eip "$doc" "Deny releasing the signal elastic IP"
  if aws iam get-group --group-name signal-team >/dev/null 2>&1; then
    aws iam attach-group-policy --group-name signal-team --policy-arn "$arn"
    log "signal-protect-eip를 그룹 signal-team에 붙임"
  else
    log "그룹 signal-team이 없어 건너뜀"
  fi
  if [[ -z "${PROTECT_EIP_USERS:-}" ]]; then
    log "PROTECT_EIP_USERS가 비어 관리자 사용자에는 붙이지 않음"
  fi
  for user in ${PROTECT_EIP_USERS:-}; do
    aws iam attach-user-policy --user-name "$user" --policy-arn "$arn"
    log "signal-protect-eip를 사용자 1명에 붙임"
  done
}

ensure_instance() {
  local id subnet sg ami root
  id=$(instance_id)
  if [[ -n "$id" ]]; then
    [[ "$id" != *[[:space:]]* ]] || die "signal-airflow 인스턴스가 여러 개다: $id"
    log "인스턴스 있음: signal-airflow $id"
    printf '%s' "$id"
    return
  fi
  subnet=$(subnet_id signal-public-2a)
  sg=$(sg_id signal-ec2-sg)
  [[ -n "$subnet" && -n "$sg" ]] || die "공개 서브넷이나 signal-ec2-sg가 없다. 01-network.sh를 먼저 실행한다"
  ami=$(aws ssm get-parameter --name "$AMI_PARAM" --query Parameter.Value --output text)
  root=$(aws ec2 describe-images --image-ids "$ami" --query 'Images[0].RootDeviceName' --output text)
  log "AMI: $ami ($AMI_PARAM, 루트 장치 $root)"
  local attempt token err
  # 같은 토큰으로 재시도하면 서버에서 이미 만든 인스턴스를 돌려주고 새로 만들지 않는다(멱등 토큰)
  token="signal-airflow-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  err=$(mktemp "${TMPDIR:-/tmp}/signal-run-instances.XXXXXX")
  for attempt in 1 2 3 4 5 6; do
    # 새로 만든 인스턴스 프로필은 몇 초 뒤에야 run-instances가 찾는다
    if id=$(aws ec2 run-instances --client-token "$token" --image-id "$ami" --instance-type t4g.small \
      --subnet-id "$subnet" --security-group-ids "$sg" \
      --iam-instance-profile "Name=$ROLE" \
      --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
      --block-device-mappings "DeviceName=$root,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
      --credit-specification CpuCredits=standard \
      --tag-specifications "$(tag_spec instance signal-airflow)" "$(tag_spec volume signal-airflow-root)" \
      --count 1 --query 'Instances[0].InstanceId' --output text 2>"$err"); then
      break
    fi
    log "run-instances 실패($attempt/6): $(tail -n 1 "$err")"
    [[ $attempt -lt 6 ]] || {
      rm -f "$err"
      die "run-instances가 계속 실패한다"
    }
    log "10초 뒤 같은 멱등 토큰으로 다시 시도"
    sleep 10
  done
  rm -f "$err"
  aws ec2 wait instance-running --instance-ids "$id"
  log "인스턴스 만듦: signal-airflow $id"
  printf '%s' "$id"
}

ensure_association() {
  local alloc=$1 instance=$2 current
  current=$(aws ec2 describe-addresses --allocation-ids "$alloc" \
    --query 'Addresses[0].InstanceId' --output text | none_to_empty)
  if [[ "$current" == "$instance" ]]; then
    log "탄력적 IP가 인스턴스에 붙어 있음"
    return
  fi
  [[ -z "$current" ]] || die "탄력적 IP가 다른 인스턴스($current)에 붙어 있다. 인스턴스 교체 절차(storage-design.md 3.4)를 따른다"
  aws ec2 associate-address --allocation-id "$alloc" --instance-id "$instance" >/dev/null
  log "탄력적 IP를 인스턴스에 붙임"
}

main() {
  local alloc instance ip
  ensure_role
  alloc=$(ensure_eip)
  ensure_protect_policy "$alloc"
  instance=$(ensure_instance)
  ensure_association "$alloc" "$instance"
  ip=$(aws ec2 describe-addresses --allocation-ids "$alloc" --query 'Addresses[0].PublicIp' --output text)
  ssm_put_string /signal/infra/eip_public_ip "$ip"
  log "공인 IP를 SSM /signal/infra/eip_public_ip에 적음(화면에는 찍지 않음)"
  log "04 완료: 인스턴스 $instance. Session Manager 등록 확인:"
  log "  aws ssm describe-instance-information --filters Key=InstanceIds,Values=$instance"
}

main "$@"
