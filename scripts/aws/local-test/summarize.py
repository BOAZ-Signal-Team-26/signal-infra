"""ec2-sim.sh 결과 폴더를 읽어 storage-design.md 3.3 합격 기준과 대조한 요약(Markdown)을 표준 출력으로 낸다.

사용: python3 summarize.py <결과 폴더>
- 사용 메모리는 cgroup anon + kernel(EC2의 `free` 「used」에 가까운 값, 페이지 캐시 제외)로 본다
- 합격 기준(제안, 3.3): 유휴 사용 메모리 1.2GB 이하·스왑 0, 추출 병렬 2로 50건 처리 중 스왑 500MB 이하, 300초 초과 파일 0건
"""

import csv
import json
import statistics
import sys
from datetime import datetime
from pathlib import Path

MB = 1024 * 1024


def rows(folder: Path) -> list[dict[str, str]]:
    with (folder / "memory.csv").open() as f:
        return list(csv.DictReader(f))


def mb(v: float) -> str:
    return f"{v / MB:,.0f}MB"


def kb(v: float) -> str:
    return f"{v / 1024:,.0f}KB"


def used(r: dict[str, str]) -> int:
    return int(r["anon"]) + int(r["kernel"] or 0)


def phase_stats(data: list[dict[str, str]], phase: str) -> dict[str, float] | None:
    sel = [r for r in data if r["phase"] == phase]
    if not sel:
        return None
    u = [used(r) for r in sel]
    return {
        "samples": len(sel),
        "used_avg": statistics.mean(u),
        "used_max": max(u),
        "current_max": max(int(r["current"]) for r in sel),
        "swap_max": max(int(r["swap"] or 0) for r in sel),
        "swap_growth": max(int(r["swap"] or 0) for r in sel)
        - min(int(r["swap"] or 0) for r in sel),
        "scheduler_avg": statistics.mean(int(r["scheduler_anon"]) for r in sel),
        "webserver_avg": statistics.mean(int(r["webserver_anon"]) for r in sel),
        "codedeploy_avg": statistics.mean(int(r["codedeploy_anon"]) for r in sel),
        "ssm_agent_avg": statistics.mean(int(r["ssm_agent_anon"]) for r in sel),
        "scheduler_max": max(int(r["scheduler_anon"]) for r in sel),
    }


def durations(folder: Path) -> list[tuple[str, float, str]]:
    out = []
    path = folder / "extraction_attempts.jsonl"
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        if not rec.get("started_at") or not rec.get("finished_at"):
            continue
        t0 = datetime.fromisoformat(rec["started_at"])
        t1 = datetime.fromisoformat(rec["finished_at"])
        out.append(
            (
                rec["source_key"],
                (t1 - t0).total_seconds(),
                rec.get("extract_status", ""),
            )
        )
    return out


def main() -> None:
    folder = Path(sys.argv[1])
    data = rows(folder)
    idle = phase_stats(data, "idle")
    ext = phase_stats(data, "extract")
    durs = durations(folder)
    print("# Airflow 2.11.2 메모리 측정 요약(EC2 흉내 컨테이너)\n")
    report = folder / "setup-report.txt"
    if report.exists():
        print("## 설치 기록\n")
        for line in report.read_text().splitlines():
            print(f"- {line}")
        print()
    print("## 측정값\n")
    print(
        "| 구간 | 표본(초) | 사용 메모리 평균 | 사용 메모리 최대 | cgroup 전체 최대(캐시 포함) | 스왑 최대 |"
    )
    print("|---|---|---|---|---|---|")
    for name, s in (("유휴", idle), ("추출 중", ext)):
        if s:
            print(
                f"| {name} | {s['samples']} | {mb(s['used_avg'])} | {mb(s['used_max'])} |"
                f" {mb(s['current_max'])} | {kb(s['swap_max'])}(구간 중 증가 {kb(s['swap_growth'])}) |"
            )
    if idle:
        print(
            "\n유휴 서비스별 anon 평균: "
            f"스케줄러 {mb(idle['scheduler_avg'])}, 웹 서버 {mb(idle['webserver_avg'])}, "
            f"CodeDeploy 에이전트 {mb(idle['codedeploy_avg'])}, SSM 에이전트 {mb(idle['ssm_agent_avg'])}"
        )
    if ext:
        print(
            f"\n추출 중 스케줄러 cgroup(작업 프로세스 포함) anon 최대: {mb(ext['scheduler_max'])}"
        )
    if durs:
        secs = [d for _, d, _ in durs]
        over = [k for k, d, _ in durs if d > 300]
        status: dict[str, int] = {}
        for _, _, st in durs:
            status[st] = status.get(st, 0) + 1
        print(
            f"\n파일별 처리 시간: {len(secs)}건, 중앙값 {statistics.median(secs):.1f}초, "
            f"최대 {max(secs):.1f}초, 300초 초과 {len(over)}건. 상태 {status}"
        )
    print("\n## 합격 기준 대조(제안 기준, storage-design.md 3.3)\n")
    if idle:
        mem_ok = idle["used_max"] <= 1.2 * 1024 * MB
        swap_ok = idle["swap_growth"] == 0
        print(
            f"- 유휴 사용 메모리 1.2GB 이하: {'통과' if mem_ok else '미달'} (최대 {mb(idle['used_max'])})"
        )
        print(
            f"- 유휴 스왑 0: 구간 중 증가 {kb(idle['swap_growth'])}, 절대값 {kb(idle['swap_max'])}. "
            f"{'증가 없음' if swap_ok else '증가 있음'}. 절대값이 0이 아니면 설치 때 밀려난 페이지가 남은 것"
        )
    if ext:
        ok = ext["swap_max"] <= 500 * MB
        print(
            f"- 추출 병렬 2 처리 중 스왑 500MB 이하: {'통과' if ok else '미달'} (스왑 최대 {kb(ext['swap_max'])})"
        )
    if durs:
        n_over = sum(1 for _, d, _ in durs if d > 300)
        print(
            f"- 300초 초과 파일 0건: {'통과' if n_over == 0 else '미달'} ({n_over}건)"
        )
    print(
        "\n- SSM 에이전트는 컨테이너에 인스턴스 메타데이터가 없어 등록하지 못하고 재시작을 반복하므로 값이 0에 가깝다. EC2에서는 상주한다"
    )
    print(
        "- 컨테이너 측정이라 cgroup에 잡히지 않는 커널 공용 메모리와 컨테이너에 없는 OS 기본 프로세스(chronyd 등)가 빠져 있다. EC2에서 다시 잰 값으로 확정한다"
    )


if __name__ == "__main__":
    main()
