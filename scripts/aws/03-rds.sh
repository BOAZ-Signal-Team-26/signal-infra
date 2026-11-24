#!/usr/bin/env bash
# 6절 5: RDS PostgreSQL(DB 서브넷 그룹, 파라미터 그룹, 인스턴스)
#
# 값(11월 8일 결정, 결정 기록은 저장 계층 설계 3.1)
# - PostgreSQL 16.15, db.t4g.micro, 단일 AZ(2a), gp3 20GB, 자동 확장 상한 50GB
# - DB 서브넷 그룹 signal-db-subnets(사설 2a·2c), 파라미터 그룹 signal-pg16(postgres16 계열, 값은 기본값)
# - 마스터 signal_admin, 비밀번호는 SSM /signal/rds/master_password(00-put-secret.sh로 먼저 넣음)
# - 자동 백업 7일, 백업 18:00–18:30 UTC, 유지 보수 일 19:00–19:30 UTC, 마이너 버전 자동 업그레이드 끔
# - 저장 암호화(aws/rds), 삭제 보호, 공개 접근 끔, 스냅숏에 태그 복사, IAM DB 인증 끔, Enhanced Monitoring 끔, 로그 내보내기 끔
# - Database Insights Standard(7일)
# - 생성 때 DB signal. airflow DB와 DB 계정 4개는 생성 뒤 SQL로 만든다(PM 담당)
# - 연장 지원(Extended Support) 등록 안 함: 주 버전 16의 표준 지원(2029년 2월)이 프로젝트 기간보다 길어 요금이 생길 일은 없지만,
#   기본값은 등록이라 명시적으로 끈다(가정, 11월 13일)
# - 만든 뒤 엔드포인트 주소를 SSM /signal/infra/rds_endpoint(String)에 적는다. 10-ec2-setup.sh가 읽는다(가정, 11월 13일)
#
# 사용: scripts/aws/03-rds.sh   (01 뒤. 다시 실행해도 됨. 인스턴스 생성은 10~20분 걸림)

source "$(dirname "$0")/lib.sh"
require aws jq

DB_ID=signal-db
ENGINE_VERSION=16.15

ensure_subnet_group() {
  local a c
  # 이름을 지정한 describe가 없을 때 오류를 내는지는 구현마다 달라 결과 개수로 판단한다
  if [[ "$(aws rds describe-db-subnet-groups --db-subnet-group-name signal-db-subnets \
    --query 'length(DBSubnetGroups)' --output text 2>/dev/null || echo 0)" == 1 ]]; then
    log "DB 서브넷 그룹 있음: signal-db-subnets"
    return
  fi
  a=$(subnet_id signal-private-2a)
  c=$(subnet_id signal-private-2c)
  [[ -n "$a" && -n "$c" ]] || die "사설 서브넷이 없다. 01-network.sh를 먼저 실행한다"
  # shellcheck disable=SC2046
  aws rds create-db-subnet-group --db-subnet-group-name signal-db-subnets \
    --db-subnet-group-description "signal private subnets 2a 2c" \
    --subnet-ids "$a" "$c" --tags $(tags_kv signal-db-subnets) >/dev/null
  log "DB 서브넷 그룹 만듦: signal-db-subnets"
}

ensure_parameter_group() {
  if [[ "$(aws rds describe-db-parameter-groups --db-parameter-group-name signal-pg16 \
    --query 'length(DBParameterGroups)' --output text 2>/dev/null || echo 0)" == 1 ]]; then
    log "파라미터 그룹 있음: signal-pg16"
    return
  fi
  # shellcheck disable=SC2046
  aws rds create-db-parameter-group --db-parameter-group-name signal-pg16 \
    --db-parameter-group-family postgres16 --description "signal postgres16 (defaults)" \
    --tags $(tags_kv signal-pg16) >/dev/null
  log "파라미터 그룹 만듦: signal-pg16"
}

ensure_instance() {
  local sg status pw
  status=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)
  if [[ -n "$status" ]]; then
    log "RDS 인스턴스 있음: $DB_ID ($status)"
    return
  fi
  ssm_param_exists /signal/rds/master_password ||
    die "SSM /signal/rds/master_password가 없다. 00-put-secret.sh /signal/rds/master_password --generate password"
  sg=$(sg_id signal-rds-sg)
  [[ -n "$sg" ]] || die "signal-rds-sg가 없다. 01-network.sh를 먼저 실행한다"
  pw=$(ssm_secret /signal/rds/master_password) || die "마스터 비밀번호를 읽지 못했다"
  [[ -n "$pw" ]] || die "마스터 비밀번호가 비었다"
  # 비밀번호를 명령 인자로 넘기지 않도록 전체 요청을 권한 600 임시 파일의 JSON으로 넘긴다
  MASTER_PW="$pw" jq -n \
    --arg id "$DB_ID" --arg ver "$ENGINE_VERSION" --arg sg "$sg" --arg az "${AWS_REGION}a" \
    --arg project "$PROJECT" '{
      DBInstanceIdentifier: $id,
      DBInstanceClass: "db.t4g.micro",
      Engine: "postgres",
      EngineVersion: $ver,
      EngineLifecycleSupport: "open-source-rds-extended-support-disabled",
      DBName: "signal",
      MasterUsername: "signal_admin",
      MasterUserPassword: env.MASTER_PW,
      AllocatedStorage: 20,
      MaxAllocatedStorage: 50,
      StorageType: "gp3",
      StorageEncrypted: true,
      DBSubnetGroupName: "signal-db-subnets",
      VpcSecurityGroupIds: [$sg],
      DBParameterGroupName: "signal-pg16",
      AvailabilityZone: $az,
      MultiAZ: false,
      PubliclyAccessible: false,
      Port: 5432,
      BackupRetentionPeriod: 7,
      PreferredBackupWindow: "18:00-18:30",
      PreferredMaintenanceWindow: "sun:19:00-sun:19:30",
      AutoMinorVersionUpgrade: false,
      DeletionProtection: true,
      CopyTagsToSnapshot: true,
      EnableIAMDatabaseAuthentication: false,
      MonitoringInterval: 0,
      DatabaseInsightsMode: "standard",
      EnablePerformanceInsights: true,
      PerformanceInsightsRetentionPeriod: 7,
      Tags: [{Key: "Project", Value: $project}, {Key: "Name", Value: $id}]
    }' | with_json_file aws rds create-db-instance --cli-input-json >/dev/null
  log "RDS 인스턴스 생성 요청: $DB_ID. 사용 가능 상태까지 기다림(10~20분)"
}

main() {
  local endpoint
  ensure_subnet_group
  ensure_parameter_group
  ensure_instance
  aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
  endpoint=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  ssm_put_string /signal/infra/rds_endpoint "$endpoint"
  log "03 완료: $DB_ID 사용 가능. 엔드포인트는 SSM /signal/infra/rds_endpoint"
  log "다음(PM 담당): airflow DB와 DB 계정 4개·권한 만들기(storage-design.md 3.6). 마이그레이션은 signal-pipeline Flyway(flyway.toml, 환경 rds)"
}

main "$@"
