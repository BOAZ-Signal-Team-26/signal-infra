# AWS 구축 스크립트

[저장 계층 설계](../../docs/storage-design.md) 6절 「구축 순서」를 AWS CLI 스크립트로 옮긴 것이다. 10월 31일 12차 미팅에서 구축 방식을 스크립트로 정했고, Terraform은 백업용이다.

- 단계마다 이름(`Name` 태그)으로 먼저 조회하고 없을 때만 만든다. 같은 스크립트를 다시 실행해도 자원이 늘지 않는다
- 만든 자원 ID를 파일로 남기지 않는다. `Project=signal` 태그로 다시 조회한다
- 계정 ID·공인 IP·IAM 사용자 이름·메일 주소를 저장소에 적지 않는다. 계정 ID는 실행 때 STS로 읽고, 사용자 이름·메일은 환경 변수로 받는다
- 비밀값은 SSM Parameter Store(SecureString)에만 둔다. 스크립트는 값을 화면·명령 인자에 남기지 않는다. 요청 JSON 임시 파일은 중단돼도 지운다
- EC2 역할은 EC2에서 쓰지 않는 DB 비밀번호(`/signal/rds/master_password`·`owner_password`·`reader_password`)를 명시적으로 거부한다

## 준비

- 로컬: AWS CLI 2.39 이상(버킷 계정 리전 네임스페이스 `--bucket-namespace` 지원), `jq`, `openssl`. RDS 마이그레이션에 Flyway 13.13.0(`brew install flyway`)
- 관리자 권한 자격 증명. 리전은 기본 `ap-northeast-2`(`AWS_REGION`으로 바꿀 수 있음)
- 6절 1(계정 준비)은 PM(대현)이 끝냄: IAM 사용자·그룹 `signal-team`, 예산 `monthly-50usd`
- 예산 `monthly-50usd`는 크레딧 차감 전 금액으로 집계해야 한다(비용 유형의 크레딧 포함 끔, `CostTypes.IncludeCredit=false`). 크레딧을 포함하면 크레딧이 남아 있는 동안 EC2 중지가 실행되지 않으므로 5번이 멈춘다

## 순서

| 순서 | 실행 | 하는 일 | 걸리는 시간 |
|---|---|---|---|
| 0 | `00-put-secret.sh /signal/rds/master_password --generate password` | RDS 마스터 비밀번호 생성·저장 | 즉시 |
| 1 | `01-network.sh` | VPC, 서브넷 3개, 인터넷 게이트웨이, 라우팅 표 2개, S3 게이트웨이 엔드포인트, 보안 그룹 2개 | 1분 |
| 2 | `02-s3.sh` | 데이터 버킷(공개 차단, 버전 관리, SSE-S3, 수명 주기, 버킷 정책) | 1분 |
| 3 | `03-rds.sh` | DB 서브넷 그룹, 파라미터 그룹, RDS PostgreSQL 16.15. 엔드포인트를 SSM `/signal/infra/rds_endpoint`에 적음 | 10~20분 |
| 4 | `PROTECT_EIP_USERS="<관리자> <관리자>" 04-ec2.sh` | 인스턴스 역할, 탄력적 IP와 해제 거부 정책, EC2 t4g.small. 공인 IP를 SSM `/signal/infra/eip_public_ip`에 적음 | 3분 |
| 5 | `BUDGET_EMAILS="<메일> <메일>" 05-budgets.sh` | 예산 동작: 실제 비용 100%에서 EC2 중지 | 1분 |
| 6 | `06-team-guardrails.sh` | 그룹 `signal-team` 보호 정책 `signal-team-guardrails`: 버킷 정책·수명 주기·버전 관리·공개 차단 변경과 버킷 삭제, RDS `signal-db` 수정·삭제, SSM `/signal/rds/*` 읽기와 경로 단위 조회, `deploy/` 쓰기·삭제, CodeDeploy 배포 생성·설정 변경 거부 | 즉시 |
| 7 | PM(대현) | `airflow` 데이터베이스와 DB 계정 4개·권한([저장 계층 설계](../../docs/storage-design.md) 3.6). `airflow` 계정 비밀번호는 SSM `/signal/rds/airflow_password` | |
| 8 | `00-put-secret.sh`로 `/signal/airflow/fernet_key`(`--generate fernet`), `webserver_secret_key`·`admin_password`(`--generate password`), `/signal/dart/api_key`(입력) | Airflow·수집 비밀값 | 즉시 |
| 9 | EC2 Session Manager 셸에서 `sudo bash 10-ec2-setup.sh --pipeline-ref <signal-pipeline 태그> --raw-root s3://<버킷>/` | 스왑, 패키지, Airflow 2.11.2, uv, signal-pipeline, systemd 서비스, CodeDeploy 에이전트 | 5~10분 |
| 10 | signal-pipeline Flyway `migrate`(로컬에서 RDS 포트 전달로, `signal_owner` 계정. [signal-pipeline PR #89](https://github.com/BOAZ-Signal-Team-26/signal-pipeline/pull/89) 병합 뒤. 아래 「로컬 결과를 옮기는 순서」 3번) | ERD 표 만들기(이력 표 `flyway_schema_history`) | 1분 |
| 11 | 로컬 결과 옮기기(아래) | DB 행과 원본 파일 | |

- 3번 RDS 생성 요청에는 Database Insights Standard(`DatabaseInsightsMode=standard`, Performance Insights 7일)를 함께 넣는다. 오류가 나면 그 두 값을 빼고 다시 실행한 뒤 콘솔에서 켠다(로컬 모의 서버로는 확인하지 못함)
- 5번 시험(설계 문서 6절 12): `BUDGET_THRESHOLD=1`로 5번을 실행해 EC2가 멈추는지 본다. 그 뒤 순서대로 실행한다
  1. `aws ec2 start-instances --instance-ids <인스턴스 ID>`로 다시 켠다
  2. 동작 ID 확인: `aws budgets describe-budget-actions-for-budget --account-id <계정 ID> --budget-name monthly-50usd --query 'Actions[].[ActionId,Status]'`
  3. `aws budgets execute-budget-action --account-id <계정 ID> --budget-name monthly-50usd --action-id <동작 ID> --execution-type RESET_BUDGET_ACTION`
  4. `aws budgets describe-budget-action --account-id <계정 ID> --budget-name monthly-50usd --action-id <동작 ID> --query Action.Status`가 `STANDBY`인지 본다
  5. `BUDGET_THRESHOLD` 없이(100%) 5번을 다시 실행한다
  - 한 번 실행된 동작이 같은 예산 기간에 다시 실행되지 않는지는 AWS 문서에서 확인하지 못했다. 그래서 되돌린 뒤 `STANDBY`를 직접 확인한다
- 9번 EC2에서 이 저장소를 받는 방법: `sudo dnf install -y git && git clone https://github.com/BOAZ-Signal-Team-26/signal-infra.git /tmp/signal-infra`
- 9번 메타데이터 DB 연결은 `sslmode=verify-full`이다. RDS 공식 리전 CA 묶음(`https://truststore.pki.rds.amazonaws.com/ap-northeast-2/ap-northeast-2-bundle.pem`)을 받아 `/opt/signal/rds-ca/`에 둔다. 아래 「RDS 접속」의 포트 전달은 호스트 이름이 `localhost`라 인증서 이름과 맞지 않으므로 `sslmode=require`를 쓴다
- 9번 관리자 계정 비밀번호는 명령 인자로 넘기지 않는다. `airflow users create`를 `--password` 없이 제어 터미널을 뗀 채(`setsid`) 실행하고 표준 입력으로 넘긴다
- Airflow 화면: `aws ssm start-session --target <인스턴스 ID> --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080` 뒤 `http://localhost:8080`
- RDS 접속: RDS는 EC2 보안 그룹에서만 5432번을 받는다. 로컬에서 `aws ssm start-session --target <인스턴스 ID> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=<RDS 엔드포인트>,portNumber=5432,localPortNumber=15432`로 EC2를 거쳐 붙는다. 엔드포인트는 SSM `/signal/infra/rds_endpoint`. 접속 문자열은 `postgresql://<계정>@localhost:15432/signal?sslmode=require`이고 비밀번호는 넣지 않는다(`PGPASSWORD`나 `~/.pgpass`)

## 로컬 결과를 옮기는 순서

로컬 PostgreSQL에 적재한 결과(prep-8 절 분할, LLM 추출 결과)를 RDS로 옮긴다. DB 행이 가리키는 파일 경로(`storage_path` 등)는 `RAW_ROOT` 기준 상대경로라, 파일도 같은 키로 S3에 올려야 한다.

절차와 근거는 signal-pipeline `docs/data-model.md` 운영 규칙(다른 DB로 데이터 옮기기)에 있다.

1. 원본 장비에서 내보내기: 로컬 PostgreSQL 16 컨테이너 안의 `pg_dump`로 데이터만 내보낸다. `docker exec signal-pg-local pg_dump -U <계정> -d signal --data-only -Fc -n raw -n staging -n mart -f /tmp/signal-data.dump`. 덤프는 컨테이너 임시 경로에만 두고 저장소나 S3 `backups/`(주간 백업 전용, 35일 보관)에 두지 않는다. `document`·`pipeline_run`의 순환 외래 키 경고는 자기 참조라 무시한다. 같은 장비에서 행 수·내용 md5를 출력해 둔다(명령은 `data-model.md`의 확인 1·2)
2. 파일 올리기: `uv run --no-project --with 'boto3>=1.36.0' python scripts/aws/20-upload-raw-root.py --raw-root <로컬 RAW_ROOT> --bucket <버킷>`. 버킷 정책상 `aws s3 sync`는 거부되므로 이 스크립트로 새 키에만 쓴다. 다시 실행하면 같은 파일은 건너뛰고, 내용이 다른 파일은 실패로 알린다
3. 표 만들기: 위 「RDS 접속」대로 포트 전달을 켜 둔 다른 터미널에서, `signal_owner` 비밀번호를 `ENVIRONMENTS_RDS_PASSWORD`로 주고 signal-pipeline 저장소 루트에서 `flyway -environment=rds migrate`(설정은 signal-pipeline `flyway.toml`, 주소 `localhost:15432/signal?sslmode=require`). 끝나면 `flyway -environment=rds info`로 적용 상태를 본다. 전제: signal-pipeline에 [signal-pipeline PR #89](https://github.com/BOAZ-Signal-Team-26/signal-pipeline/pull/89)(Flyway 전환)가 병합된 상태에서 그 저장소의 dev를 받아 실행한다. 병합 전 버전에는 `flyway.toml`과 `V1__erd_v2_2.sql`이 없다. RDS `signal` DB는 이때 비어 있어야 한다. 행이 있으면 DB를 새로 만든다
4. 넣기: 같은 컨테이너의 `pg_restore`로 포트 전달에 붙는다(컨테이너에서 Mac의 `localhost`는 `host.docker.internal`). `docker exec -e PGPASSWORD signal-pg-local pg_restore -h host.docker.internal -p 15432 -U signal_owner -d 'dbname=signal sslmode=require' --data-only --single-transaction --exit-on-error /tmp/signal-data.dump`. `pg_restore`는 표 소유자인 `signal_owner`로 실행한다. RDS 마스터는 INSERT·시퀀스 값 설정 권한이 없다. 한 트랜잭션이라 실패하면 전부 롤백된다
5. 확인: RDS의 행 수·내용 md5를 출력해 1번 값과 비교한다. 같으면 `docker exec signal-pg-local rm /tmp/signal-data.dump`로 덤프를 지운다. 그 뒤 `uv run python -m signal_pipeline.loading.load_checks <RAW_ROOT>`(S3 전환 뒤)

## 로컬 검증(실제 AWS에 접속하지 않음)

| 스크립트 | 확인하는 것 | 확인하지 못하는 것 |
|---|---|---|
| `local-test/moto-test.sh` | 00~06이 모의 AWS(moto)에서 끝까지 돌고, 두 번 실행해도 자원이 늘지 않고, 이름·태그·주요 설정이 결정값과 같은지. EC2 역할의 DB 비밀번호 거부 문, 버킷 정책의 TLS 거부 문, 할당 ID가 바뀐 `signal-protect-eip` 정책을 다시 실행할 때 고치는지, 크레딧을 포함하는 예산이면 5번이 멈추는지 | 버킷 정책·IAM 거부의 실제 평가, 계정 리전 네임스페이스 이름 규칙, RDS 엔진 버전 검증, Budgets 동작(모의 서버 미지원) |
| `local-test/ec2-sim.sh --raw-dir <RAW_ROOT> [--rerun]` | 10번을 Amazon Linux 2023 arm64 컨테이너(systemd, 메모리 2GB·CPU 2개)에서 그대로 실행하고, 유휴·추출 병렬 2 처리 중 메모리를 1초 간격으로 기록. 메타데이터 DB 연결은 모의 RDS의 자체 서명 인증서로 `verify-full`. `--rerun`이면 10번을 한 번 더 실행 | cgroup에 잡히지 않는 커널 공용 메모리와 OS 기본 프로세스 일부, 스왑 2GB(Docker VM 스왑 1GB를 씀)와 스왑 단계의 다시 실행, 중간에 끊긴 뒤 다시 실행, RDS 공식 CA 묶음 내려받기, CPU 크레딧 |

- 두 스크립트 모두 Docker가 필요하다. 끝나면 컨테이너를 지운다(`ec2-sim.sh --keep`이면 남김)
- 구축 뒤 확인 항목은 [저장 계층 설계](../../docs/storage-design.md) 6절 12를 따른다

## 종료

[저장 계층 설계](../../docs/storage-design.md) 6절 「프로젝트 종료 절차」를 따른다. 정리 스크립트는 만들지 않는다(11월 8일 결정).
