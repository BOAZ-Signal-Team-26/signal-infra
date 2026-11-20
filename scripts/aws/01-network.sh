#!/usr/bin/env bash
# 6절 3: VPC, 서브넷 3개, 인터넷 게이트웨이, 라우팅 표 2개, S3 게이트웨이 엔드포인트, 보안 그룹 2개
#
# 값(11월 8일 결정): VPC 10.0.0.0/16, 공개 2a 10.0.0.0/24, 사설 2a 10.0.10.0/24, 사설 2c 10.0.11.0/24.
# 10.0.1.0/24는 공개 2c용으로 비워 두고 만들지 않는다. NAT 게이트웨이 없음. 공인 IP 자동 할당 끔(탄력적 IP를 붙임).
# S3 게이트웨이 엔드포인트는 공개 라우팅 표에만 연결한다(S3를 쓰는 것은 EC2뿐).
# 보안 그룹: EC2 인바운드 없음·아웃바운드 전체, RDS는 EC2 보안 그룹에서 5432만.
#
# 사용: scripts/aws/01-network.sh   (다시 실행해도 됨)

source "$(dirname "$0")/lib.sh"
require aws

VPC_CIDR=10.0.0.0/16

ensure_vpc() {
  local id
  id=$(vpc_id)
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "$(tag_spec vpc signal-vpc)" \
      --query Vpc.VpcId --output text)
    aws ec2 wait vpc-available --vpc-ids "$id"
    log "VPC 만듦: signal-vpc $id"
  else
    local cidr
    cidr=$(aws ec2 describe-vpcs --vpc-ids "$id" --query 'Vpcs[0].CidrBlock' --output text)
    [[ "$cidr" == "$VPC_CIDR" ]] || die "signal-vpc CIDR가 ${cidr}이다(${VPC_CIDR}이어야 함)"
    log "VPC 있음: signal-vpc $id"
  fi
  # RDS 엔드포인트 이름 풀이와 Session Manager 접속에 필요
  aws ec2 modify-vpc-attribute --vpc-id "$id" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$id" --enable-dns-hostnames '{"Value":true}'
}

ensure_igw() {
  local vpc=$1 id attached
  # shellcheck disable=SC2046
  id=$(aws ec2 describe-internet-gateways --filters $(ec2_filter_name signal-igw) \
    --query 'InternetGateways[0].InternetGatewayId' --output text | none_to_empty)
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-internet-gateway \
      --tag-specifications "$(tag_spec internet-gateway signal-igw)" \
      --query InternetGateway.InternetGatewayId --output text)
    log "인터넷 게이트웨이 만듦: signal-igw $id"
  else
    log "인터넷 게이트웨이 있음: signal-igw $id"
  fi
  attached=$(aws ec2 describe-internet-gateways --internet-gateway-ids "$id" \
    --query 'InternetGateways[0].Attachments[0].VpcId' --output text | none_to_empty)
  if [[ -z "$attached" ]]; then
    aws ec2 attach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc"
    log "인터넷 게이트웨이를 VPC에 붙임"
  elif [[ "$attached" != "$vpc" ]]; then
    die "signal-igw가 다른 VPC($attached)에 붙어 있다"
  fi
  printf '%s' "$id"
}

ensure_subnet() {
  local vpc=$1 name=$2 cidr=$3 az=$4 id
  id=$(subnet_id "$name")
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "$cidr" \
      --availability-zone "$az" \
      --tag-specifications "$(tag_spec subnet "$name")" \
      --query Subnet.SubnetId --output text)
    log "서브넷 만듦: $name $cidr $az $id"
  else
    local got
    got=$(aws ec2 describe-subnets --subnet-ids "$id" \
      --query 'Subnets[0].[CidrBlock,AvailabilityZone]' --output text)
    [[ "$got" == "$cidr"$'\t'"$az" ]] || die "${name}이 ${got//$'\t'/ }이다($cidr ${az}이어야 함)"
    log "서브넷 있음: $name $id"
  fi
  aws ec2 modify-subnet-attribute --subnet-id "$id" --no-map-public-ip-on-launch
  printf '%s' "$id"
}

ensure_route_table() {
  local vpc=$1 name=$2 id
  id=$(route_table_id "$name")
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-route-table --vpc-id "$vpc" \
      --tag-specifications "$(tag_spec route-table "$name")" \
      --query RouteTable.RouteTableId --output text)
    log "라우팅 표 만듦: $name $id"
  else
    log "라우팅 표 있음: $name $id"
  fi
  printf '%s' "$id"
}

associate() {
  local rtb=$1 subnet=$2 current
  current=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$subnet" \
    --query 'RouteTables[0].RouteTableId' --output text | none_to_empty)
  if [[ "$current" == "$rtb" ]]; then return; fi
  if [[ -n "$current" ]]; then
    die "서브넷 ${subnet}이 다른 라우팅 표($current)에 연결돼 있다"
  fi
  aws ec2 associate-route-table --route-table-id "$rtb" --subnet-id "$subnet" >/dev/null
  log "서브넷 ${subnet}을 라우팅 표 ${rtb}에 연결함"
}

ensure_default_route() {
  local rtb=$1 igw=$2 target
  target=$(aws ec2 describe-route-tables --route-table-ids "$rtb" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" \
    --output text | none_to_empty)
  if [[ -z "$target" ]]; then
    aws ec2 create-route --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 \
      --gateway-id "$igw" >/dev/null
    log "공개 라우팅 표에 0.0.0.0/0 → 인터넷 게이트웨이 경로 추가"
  elif [[ "$target" != "$igw" ]]; then
    die "공개 라우팅 표의 0.0.0.0/0이 ${target}을 가리킨다"
  fi
}

ensure_s3_endpoint() {
  local vpc=$1 rtb=$2 service id
  service="com.amazonaws.$AWS_REGION.s3"
  id=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$vpc" "Name=service-name,Values=$service" \
    "Name=vpc-endpoint-type,Values=Gateway" "Name=vpc-endpoint-state,Values=available,pending" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text | none_to_empty)
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-vpc-endpoint --vpc-id "$vpc" --vpc-endpoint-type Gateway \
      --service-name "$service" --route-table-ids "$rtb" \
      --tag-specifications "$(tag_spec vpc-endpoint signal-s3-endpoint)" \
      --query VpcEndpoint.VpcEndpointId --output text)
    log "S3 게이트웨이 엔드포인트 만듦: $id"
  else
    local rtbs
    rtbs=$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$id" \
      --query 'VpcEndpoints[0].RouteTableIds' --output text)
    [[ " $rtbs " == *" $rtb "* ]] || die "S3 엔드포인트 ${id}가 공개 라우팅 표에 연결돼 있지 않다"
    log "S3 게이트웨이 엔드포인트 있음: $id"
  fi
}

ensure_sg() {
  local vpc=$1 name=$2 desc=$3 id
  id=$(sg_id "$name")
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-security-group --vpc-id "$vpc" --group-name "$name" \
      --description "$desc" \
      --tag-specifications "$(tag_spec security-group "$name")" \
      --query GroupId --output text)
    log "보안 그룹 만듦: $name $id"
  else
    log "보안 그룹 있음: $name $id"
  fi
  printf '%s' "$id"
}

ensure_no_inbound() {
  local sg=$1 n
  n=$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'length(SecurityGroups[0].IpPermissions)' --output text)
  [[ "$n" == "0" ]] || die "보안 그룹 ${sg}에 인바운드 규칙이 ${n}개 있다(없어야 함)"
}

ensure_rds_ingress() {
  local rds_sg=$1 ec2_sg=$2 rules
  rules=$(aws ec2 describe-security-groups --group-ids "$rds_sg" --output json \
    --query 'SecurityGroups[0].IpPermissions')
  if [[ "$rules" == *"\"$ec2_sg\""* ]]; then
    log "RDS 보안 그룹 5432 규칙 있음"
    return
  fi
  aws ec2 authorize-security-group-ingress --group-id "$rds_sg" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$ec2_sg,Description=signal-ec2-sg}]" \
    >/dev/null
  log "RDS 보안 그룹에 signal-ec2-sg → 5432 허용 추가"
}

main() {
  local vpc igw pub priv_a priv_c pub_rt priv_rt ec2_sg rds_sg
  ensure_vpc
  vpc=$(vpc_id)
  igw=$(ensure_igw "$vpc")
  pub=$(ensure_subnet "$vpc" signal-public-2a 10.0.0.0/24 "${AWS_REGION}a")
  priv_a=$(ensure_subnet "$vpc" signal-private-2a 10.0.10.0/24 "${AWS_REGION}a")
  priv_c=$(ensure_subnet "$vpc" signal-private-2c 10.0.11.0/24 "${AWS_REGION}c")
  pub_rt=$(ensure_route_table "$vpc" signal-public-rt)
  priv_rt=$(ensure_route_table "$vpc" signal-private-rt)
  ensure_default_route "$pub_rt" "$igw"
  associate "$pub_rt" "$pub"
  associate "$priv_rt" "$priv_a"
  associate "$priv_rt" "$priv_c"
  ensure_s3_endpoint "$vpc" "$pub_rt"
  ec2_sg=$(ensure_sg "$vpc" signal-ec2-sg "signal EC2 - no inbound")
  rds_sg=$(ensure_sg "$vpc" signal-rds-sg "signal RDS - 5432 from signal-ec2-sg only")
  ensure_no_inbound "$ec2_sg"
  ensure_rds_ingress "$rds_sg" "$ec2_sg"
  log "01 완료: VPC $vpc, 공개 서브넷 $pub, 사설 서브넷 $priv_a $priv_c"
}

main "$@"
