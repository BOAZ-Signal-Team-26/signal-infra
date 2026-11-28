-- 2단계(Flyway V1__erd_v2_2.sql 적용 직후): signal_owner로 signal DB에 접속해 실행
-- 목적: docs/storage-design.md 3.6절 계정 권한 적용
--   - signal_pipeline (Airflow): raw·staging·mart 읽기·쓰기(TRUNCATE 제외)·시퀀스 + 향후 생성 표 기본 권한
--   - signal_reader   (대시보드·분석): mart 읽기 전용 + 향후 생성 표 기본 권한(raw·staging 접근 불가)
-- 다시 실행해도 안전하다(멱등).

\set ON_ERROR_STOP on

BEGIN;

-- signal_pipeline: 3개 스키마 읽기·쓰기(Airflow DAG 및 적재 스크립트용, TRUNCATE는 소유자 전용)
GRANT USAGE ON SCHEMA raw, staging, mart TO signal_pipeline;
REVOKE TRUNCATE ON ALL TABLES IN SCHEMA raw, staging, mart FROM signal_pipeline;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON ALL TABLES IN SCHEMA raw, staging, mart
  TO signal_pipeline;
GRANT USAGE, SELECT, UPDATE
  ON ALL SEQUENCES IN SCHEMA raw, staging, mart
  TO signal_pipeline;

ALTER DEFAULT PRIVILEGES FOR ROLE signal_owner IN SCHEMA raw, staging, mart
  REVOKE TRUNCATE ON TABLES FROM signal_pipeline;
ALTER DEFAULT PRIVILEGES FOR ROLE signal_owner IN SCHEMA raw, staging, mart
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO signal_pipeline;
ALTER DEFAULT PRIVILEGES FOR ROLE signal_owner IN SCHEMA raw, staging, mart
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO signal_pipeline;

-- signal_reader: mart 읽기 전용(raw·staging 명시적 회수)
REVOKE ALL ON SCHEMA raw, staging FROM signal_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA raw, staging FROM signal_reader;
GRANT USAGE ON SCHEMA mart TO signal_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO signal_reader;

ALTER DEFAULT PRIVILEGES FOR ROLE signal_owner IN SCHEMA mart
  GRANT SELECT ON TABLES TO signal_reader;

COMMIT;

-- 스키마·표 권한 요약 확인
SELECT
  n.nspname AS schema_name,
  r.rolname AS role_name,
  has_schema_privilege(r.rolname, n.oid, 'USAGE') AS can_use,
  has_schema_privilege(r.rolname, n.oid, 'CREATE') AS can_create
FROM pg_namespace n
CROSS JOIN (VALUES ('signal_owner'), ('signal_pipeline'), ('signal_reader')) AS r(rolname)
WHERE n.nspname IN ('raw', 'staging', 'mart')
ORDER BY n.nspname, r.rolname;
