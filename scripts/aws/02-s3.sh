#!/usr/bin/env bash
# 6절 4: S3 데이터 버킷(버전 관리, 공개 차단, 기본 암호화, 수명 주기, 버킷 정책)
#
# 값(11월 8일 결정)
# - 버킷 이름 signal-data-{계정 ID}-{리전}-an. 계정 리전 네임스페이스(--bucket-namespace account-regional)라
#   이 계정만 이 이름을 만들 수 있다. 계정 ID는 실행 때 STS로 읽고 저장소에는 적지 않는다
# - 공개 차단 4개 켬, 버전 관리 켬, SSE-S3
# - 수명 주기: policies/bucket-lifecycle.json (storage-design.md 3.2·3.7)
# - 버킷 정책: policies/bucket-policy.json
#   - raw/·runs/·assets/ 삭제 거부
#   - raw/·runs/·assets/에 If-None-Match 없는 쓰기 거부(조건 키 s3:if-none-match, 멀티파트 조각은 s3:ObjectCreationOperation으로 제외)
#   - eval/ 읽기는 EVAL_ROLE(기본 signal-eval, PM 확인 전 이름 후보)만 허용
#
# 사용: scripts/aws/02-s3.sh   (다시 실행해도 됨. 수명 주기와 버킷 정책은 매번 파일 내용으로 덮어씀)
# 확인: 이 단계 뒤 RAW_ROOT=s3://$(버킷 이름)/ 이다. RAW_ROOT는 EC2 환경 설정(/etc/sysconfig/airflow)에만 둔다

source "$(dirname "$0")/lib.sh"
require aws

EVAL_ROLE="${EVAL_ROLE:-signal-eval}"

main() {
  local bucket
  bucket=$(bucket_name)
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    log "버킷 있음: $bucket"
  else
    aws s3api create-bucket --bucket "$bucket" --bucket-namespace account-regional \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    aws s3api wait bucket-exists --bucket "$bucket"
    log "버킷 만듦: $bucket"
  fi

  aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-tagging --bucket "$bucket" \
    --tagging "TagSet=[{Key=Project,Value=$PROJECT},{Key=Name,Value=signal-data}]"
  aws s3api put-bucket-lifecycle-configuration --bucket "$bucket" \
    --lifecycle-configuration "file://$POLICY_DIR/bucket-lifecycle.json" >/dev/null
  aws s3api put-bucket-policy --bucket "$bucket" --policy \
    "$(render "$POLICY_DIR/bucket-policy.json" "BUCKET=$bucket" \
      "ACCOUNT_ID=$(account_id)" "EVAL_ROLE=$EVAL_ROLE")"
  log "버킷 설정 적용: 공개 차단, 버전 관리, SSE-S3, 태그, 수명 주기, 버킷 정책(eval 역할 $EVAL_ROLE)"
  log "02 완료: RAW_ROOT=s3://$bucket/ (EC2 환경 설정에만 적는다)"
}

main "$@"
