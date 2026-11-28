-- 1단계(Flyway 실행 전): RDS 마스터(signal_admin)로 signal DB에 접속해 실행
-- 목적: DB 계정 4개(signal_owner, signal_pipeline, signal_reader, airflow),
--       airflow DB 생성, signal DB 소유자 전환(signal_owner), 최소 접속 권한 설정.
-- 비밀번호는 psql 변수(:owner_pw, :pipeline_pw, :reader_pw, :airflow_pw)로 전달한다(07-rds-init.sh).
-- 트랜잭션 로컬 GUC(is_local=true)를 써서 COMMIT 시 비밀번호가 세션에서 즉시 사라지며,
-- SELECT 결과로 비밀번호 원문을 출력하지 않는다. 다시 실행해도 안전하다(멱등).

\set ON_ERROR_STOP on

BEGIN;

SELECT
  length(set_config('signal.owner_pw', :'owner_pw', true)) > 0 AS owner_pw_set,
  length(set_config('signal.pipeline_pw', :'pipeline_pw', true)) > 0 AS pipeline_pw_set,
  length(set_config('signal.reader_pw', :'reader_pw', true)) > 0 AS reader_pw_set,
  length(set_config('signal.airflow_pw', :'airflow_pw', true)) > 0 AS airflow_pw_set;

DO $$
DECLARE
  r text;
  pw text;
  role_map text[][] := ARRAY[
    ARRAY['signal_owner',    current_setting('signal.owner_pw')],
    ARRAY['signal_pipeline', current_setting('signal.pipeline_pw')],
    ARRAY['signal_reader',   current_setting('signal.reader_pw')],
    ARRAY['airflow',         current_setting('signal.airflow_pw')]
  ];
BEGIN
  FOR i IN 1..array_length(role_map, 1) LOOP
    r := role_map[i][1];
    pw := role_map[i][2];
    IF pw IS NULL OR length(pw) = 0 THEN
      RAISE EXCEPTION '비밀번호가 비어 있음: %', r;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format(
        'CREATE ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L',
        r, pw
      );
    ELSE
      EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', r, pw);
    END IF;
  END LOOP;
END
$$;

COMMIT;

-- RDS PostgreSQL 16(rds_superuser): 마스터가 대상 역할의 멤버여야 DB 소유자 지정·생성이 가능하다
GRANT signal_owner TO CURRENT_USER;
GRANT airflow TO CURRENT_USER;

-- signal DB 소유자를 마이그레이션 전용 계정(signal_owner)으로 전환
-- PostgreSQL 15+에서 public 스키마 소유자는 pg_database_owner(= signal_owner)로 자동 연계됨
ALTER DATABASE signal OWNER TO signal_owner;

-- airflow 메타데이터 DB 생성(트랜잭션 밖 실행을 위해 \gexec 사용)
SELECT 'CREATE DATABASE airflow OWNER airflow'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'airflow')\gexec

-- 최소 접속 권한: PUBLIC 접속·TEMP 차단 후 필요한 계정만 허용
REVOKE ALL ON DATABASE signal FROM PUBLIC;
GRANT CONNECT, TEMP ON DATABASE signal TO signal_owner, signal_pipeline;
GRANT CONNECT ON DATABASE signal TO signal_reader;

REVOKE ALL ON DATABASE airflow FROM PUBLIC;
GRANT CONNECT, TEMP ON DATABASE airflow TO airflow;

-- signal DB public 스키마 쓰기 차단(소유자 signal_owner만 Flyway 이력 표 생성 가능)
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- 실행 결과 확인
SELECT rolname, rolcanlogin, rolsuper
FROM pg_roles
WHERE rolname IN ('signal_owner', 'signal_pipeline', 'signal_reader', 'airflow')
ORDER BY rolname;

SELECT d.datname, pg_get_userbyid(d.datdba) AS owner
FROM pg_database d
WHERE d.datname IN ('signal', 'airflow')
ORDER BY d.datname;
