"""리허설 전용 DAG. EC2 설정(10-ec2-setup.sh) 뒤 Airflow + signal-pipeline 가상환경이 같은 Python 3.12로 도는지와
추출 병렬 2 실행 중 메모리를 재기 위해 ec2-sim.sh가 넣는다. 운영 DAG가 아니며 signal-pipeline 저장소에 넣지 않는다.

작업 방식은 signal-pipeline docs/architecture.md 2-3을 따른다: BashOperator로 `uv run python -m signal_pipeline.<모듈>`,
공유 pool signal_cpu(슬롯 2)를 추출 작업이 2슬롯 모두 차지, DAG마다 max_active_runs=1.
"""

from datetime import UTC, datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator

with DAG(
    dag_id="signal_smoke_extract",
    start_date=datetime(2026, 11, 1, tzinfo=UTC),
    schedule=None,
    catchup=False,
    max_active_runs=1,
    tags=["local-test"],
) as dag:
    BashOperator(
        task_id="extract",
        bash_command=(
            "cd /opt/signal/signal-pipeline && "
            "uv run python -m signal_pipeline.parsing.extract --limit {{ dag_run.conf.get('limit', 50) }}"
        ),
        pool="signal_cpu",
        pool_slots=2,
        execution_timeout=timedelta(minutes=90),
    )
