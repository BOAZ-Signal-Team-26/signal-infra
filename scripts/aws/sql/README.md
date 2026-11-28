# RDS DB·계정 초기화 SQL (PM 담당 7번 단계)

[저장 계층 설계](../../../docs/storage-design.md) 3.6절·6절 11과 [AWS 구축 스크립트 README](../README.md) 7번·10번에 대응하는 SQL 및 실행 스크립트다.

## 실행 전 PM 확인 체크리스트

- [ ] AWS Budgets `monthly-50usd`의 크레딧 포함이 꺼져 있음(`CostTypes.IncludeCredit=false`, 켜져 있으면 `05-budgets.sh` 중단)
- [ ] 무료 요금제 종료 안내 메일 수신 주소가 PM(대현) 메일인지 확인, 유료 전환 시 남은 크레딧 유지 여부 확인(12월 1일)
- [ ] Session Manager 원격 포트 전달로 RDS 5432번이 로컬 `15432`번에 연결되어 있음

## 실행 순서 (2단계)

1. **1단계 — 계정 4개 + `airflow` DB 생성 + `signal` 소유자 전환 (Flyway 전)**
   ```bash
   scripts/aws/07-rds-init.sh --phase roles --generate-secrets
   ```
   - SSM에 `/signal/rds/{owner,pipeline,reader,airflow}_password`가 없으면 자동 생성한다.
   - RDS 마스터(`signal_admin`)로 `01-init-roles-dbs.sql`을 실행해 계정 4개와 `airflow` DB를 만들고 `signal` 소유자를 `signal_owner`로 바꾼다.
2. **Flyway 마이그레이션 (signal-pipeline 저장소)**
   ```bash
   ENVIRONMENTS_RDS_PASSWORD="$(aws ssm get-parameter --name /signal/rds/owner_password --with-decryption --query Parameter.Value --output text)" \
     flyway -environment=rds migrate
   ```
3. **2단계 — 스키마·표·시퀀스 권한 및 기본 권한 부여 (Flyway 직후)**
   ```bash
   scripts/aws/07-rds-init.sh --phase grants
   ```
   - `signal_owner`로 `02-grant-signal-privs.sql`을 실행해 `signal_pipeline`(3스키마 읽기·쓰기)과 `signal_reader`(`mart` 읽기 전용) 권한과 향후 생성 표의 기본 권한(`ALTER DEFAULT PRIVILEGES`)을 부여한다.

## 권한 요약

| 계정 | 접속 DB | 권한 |
|---|---|---|
| `signal_owner` | `signal` | DB·스키마·표 소유자. Flyway 마이그레이션·`pg_restore` 전용 |
| `signal_pipeline` | `signal` | `raw`·`staging`·`mart` 표·시퀀스 읽기·쓰기(Airflow DAG) |
| `signal_reader` | `signal` | `mart` 읽기 전용(`raw`·`staging` 접근 불가) |
| `airflow` | `airflow` | `airflow` DB 소유자(`signal` 접속 불가) |
