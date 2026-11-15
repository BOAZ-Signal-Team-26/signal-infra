"""로컬 RAW_ROOT의 raw/·derived/·runs/ 파일을 S3 데이터 버킷의 같은 키로 올린다(한 번만 하는 이전 작업).

버킷 정책이 raw/·runs/·assets/에 If-None-Match 없는 쓰기를 거부하므로 `aws s3 sync`·`aws s3 cp`는 쓸 수 없다
(storage-design.md 3.2). 이 스크립트는 파일마다 put_object(IfNoneMatch="*")로 새 키에만 쓴다.

규칙(storage-design.md 3.2 「이미 있는 키에 조건부 쓰기가 실패했을 때」)
- 키가 이미 있으면(412) 저장된 객체의 SHA-256을 올리려던 바이트와 비교한다. 같으면 성공으로 보고 넘어가고,
  다르면 실패로 기록한다. 그래서 중간에 멈춘 뒤 다시 실행해도 된다
- 올릴 때 SHA-256 체크섬을 함께 저장해(ChecksumAlgorithm=SHA256) 나중에 같은 방법으로 대조할 수 있다
- derived/도 같은 방식으로 쓴다(덮어쓰지 않음). 다른 내용이 이미 있으면 실패로 남기고 사람이 판단한다
- state/(워터마크 임시 파일)는 올리지 않는다(DB source_watermark로 옮김, architecture.md 3-3)
- 8MB를 넘는 파일도 멀티파트 없이 한 번에 올린다(put_object 한도 5GB)
- 저장된 체크섬은 전체 객체 체크섬(ChecksumType FULL_OBJECT)일 때만 쓴다. 다른 도구로 멀티파트 업로드한 객체의
  합성 체크섬(`xxx-N`)은 바이트 해시가 아니므로 본문을 받아 해시로 비교한다
- 네트워크 오류(시간 초과, 연결 실패)도 그 파일만 error로 기록하고 나머지를 계속 올린다
- 대상 파일이 0개면 --raw-root를 잘못 준 것으로 보고 종료 코드 1

사용(원본 파일이 있는 장비에서, AWS 자격 증명 필요)
  uv run --with 'boto3>=1.36.0' python scripts/aws/20-upload-raw-root.py --raw-root <로컬 경로> --bucket <버킷 이름> --dry-run
  uv run --with 'boto3>=1.36.0' python scripts/aws/20-upload-raw-root.py --raw-root <로컬 경로> --bucket <버킷 이름>
  버킷 이름은 02-s3.sh가 출력한 RAW_ROOT의 이름(signal-data-{계정 ID}-{리전}-an)
"""

import argparse
import base64
import hashlib
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

PREFIXES = ("raw", "derived", "runs")


@dataclass
class Result:
    key: str
    outcome: str  # uploaded / same / different / error
    detail: str = ""


def files(root: Path) -> list[Path]:
    out = []
    for prefix in PREFIXES:
        base = root / prefix
        if base.is_dir():
            out += sorted(
                p for p in base.rglob("*") if p.is_file() and p.name != ".DS_Store"
            )
    return out


def upload(s3, bucket: str, root: Path, path: Path) -> Result:
    key = path.relative_to(root).as_posix()
    data = path.read_bytes()
    digest = hashlib.sha256(data).digest()
    try:
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=data,
            IfNoneMatch="*",
            ChecksumAlgorithm="SHA256",
            ChecksumSHA256=base64.b64encode(digest).decode(),
        )
        return Result(key, "uploaded")
    except BotoCoreError as e:
        return Result(key, "error", f"{type(e).__name__} {e}")
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if (
            code not in ("PreconditionFailed", "ConditionalRequestConflict")
            and status != 412
        ):
            return Result(key, "error", f"{code} {e}")
    # 이미 있는 키: 저장된 바이트와 비교
    try:
        head = s3.head_object(Bucket=bucket, Key=key, ChecksumMode="ENABLED")
        stored = head.get("ChecksumSHA256")
        if stored is not None and head.get("ChecksumType") == "FULL_OBJECT":
            same = base64.b64decode(stored) == digest
        else:
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
            same = hashlib.sha256(body).digest() == digest
    except (ClientError, BotoCoreError) as e:
        return Result(key, "error", f"이미 있는 객체 확인 실패: {e}")
    return Result(key, "same" if same else "different")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--raw-root", type=Path, required=True)
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--region", default="ap-northeast-2")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--dry-run", action="store_true", help="올릴 파일 수와 크기만 출력")
    args = ap.parse_args(argv)
    root = args.raw_root.resolve()
    todo = files(root)
    size = sum(p.stat().st_size for p in todo)
    by_prefix = {
        p: sum(1 for f in todo if f.relative_to(root).parts[0] == p) for p in PREFIXES
    }
    print(f"대상 {len(todo)}개 파일, {size / 1024 / 1024:,.1f}MB, 접두어별 {by_prefix}")
    if not todo:
        print(
            f"올릴 파일이 없다. --raw-root 아래 {', '.join(PREFIXES)} 폴더를 확인한다",
            file=sys.stderr,
        )
        return 1
    if args.dry_run:
        return 0
    s3 = boto3.client(
        "s3",
        region_name=args.region,
        config=Config(retries={"mode": "standard", "max_attempts": 5}),
    )
    counts: dict[str, int] = {}
    problems: list[Result] = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(upload, s3, args.bucket, root, p) for p in todo]
        for n, fut in enumerate(as_completed(futures), 1):
            r = fut.result()
            counts[r.outcome] = counts.get(r.outcome, 0) + 1
            if r.outcome in ("different", "error"):
                problems.append(r)
            if n % 500 == 0:
                print(f"  {n}/{len(todo)} {counts}", flush=True)
    print(f"끝: {counts}")
    for r in problems:
        print(f"  {r.outcome}: {r.key} {r.detail}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
