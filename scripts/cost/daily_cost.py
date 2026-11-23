"""시간별 CUR 2.0을 한국 날짜로 집계해 Slack에 보낸다. 비밀값은 반환·로그하지 않는다."""

import csv
import gzip
import io
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, time, timedelta, timezone
from decimal import Decimal

import boto3
from botocore.config import Config

UTC = timezone.utc
KST = timezone(timedelta(hours=9))
ZERO = Decimal("0")
ADJUSTMENTS = {"Credit", "Refund"}
SDK_CONFIG = Config(connect_timeout=5, read_timeout=25,
                    retries={"mode": "standard", "total_max_attempts": 3})


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("CUR timestamp must include timezone")
    return parsed.astimezone(UTC)


def report_days(now):
    today = now.astimezone(KST).date()
    return [today - timedelta(days=n) for n in (1, 2, 3)]


def required_months(now):
    months = {now.astimezone(UTC).strftime("%Y-%m")}
    for day in report_days(now):
        start = datetime.combine(day, time(), KST).astimezone(UTC)
        months.add(start.strftime("%Y-%m"))
        months.add((start + timedelta(days=1, microseconds=-1)).strftime("%Y-%m"))
    return sorted(months)


def usage_category(row):
    """제품 코드가 아닌 사용 유형으로 분류한다. 모르는 유형은 원문을 보존한다."""
    product = row["line_item_product_code"]
    usage = row.get("line_item_usage_type", "").strip()
    if not usage:
        return f"{product} (세부 사용 유형 수신 대기)"
    # 지역 접두사가 붙어도 같은 과금 항목을 식별한다.
    if product in {"AmazonEC2", "AmazonVPC"}:
        rules = [("NatGateway-Hours", "NAT Gateway 시간 요금"),
                 ("NatGateway-Bytes", "NAT Gateway 데이터 처리"),
                 ("PublicIPv4:InUseAddress", "공인 IPv4 사용 중"),
                 ("PublicIPv4:IdleAddress", "공인 IPv4 미사용"),
                 ("VPN-Usage-Hours:", "Site-to-Site VPN 시간 요금"),
                 ("EBS:Snapshot", "EBS 스냅샷"),
                 ("EBS:Volume", "EBS 볼륨"),
                 ("EBS:", "EBS 기타")]
        for token, label in rules:
            if token in usage:
                return label
        for token, label in [("BoxUsage:", "EC2 인스턴스"), ("SpotUsage:", "EC2 Spot 인스턴스")]:
            if token in usage:
                return f"{label} ({usage.split(token, 1)[1]})"
    if "DataTransfer" in usage or "AWS-Out-Bytes" in usage or "AWS-In-Bytes" in usage:
        return f"데이터 전송 ({product} / {usage})"
    if product == "AmazonEKS" and "perCluster" in usage:
        return "EKS 클러스터 시간 요금"
    if product == "AmazonS3":
        if "TimedStorage" in usage:
            return "S3 저장 공간"
        if "Requests-" in usage:
            return f"S3 요청 ({usage})"
    if product == "AmazonDynamoDB":
        for token, label in [("ReadRequestUnits", "DynamoDB 읽기 요청"),
                             ("WriteRequestUnits", "DynamoDB 쓰기 요청"),
                             ("TimedPITRStorage", "DynamoDB PITR 백업 저장"),
                             ("TimedStorage", "DynamoDB 저장 공간")]:
            if token in usage:
                return label
    return f"{product} / {usage}"


def aggregate(rows, account, now):
    days = {day.isoformat(): {"cost": ZERO, "rows": 0, "services": defaultdict(lambda: ZERO)}
            for day in report_days(now)}
    month = now.astimezone(UTC).strftime("%Y-%m")
    totals = {"before": ZERO, "credit": ZERO, "refund": ZERO, "after": ZERO, "rows": 0}
    unallocated = 0
    row_count = 0
    for row in rows:
        row_count += 1
        if row["line_item_usage_account_id"] != account:
            continue
        if row["line_item_currency_code"] != "USD":
            raise ValueError("Unexpected billing currency")
        raw = row.get("line_item_net_unblended_cost") or row["line_item_unblended_cost"]
        cost = Decimal(raw)
        if not cost.is_finite():
            raise ValueError("Invalid CUR amount")
        kind = row["line_item_line_item_type"]
        billing_month = timestamp(row["bill_billing_period_start_date"]).strftime("%Y-%m")
        if billing_month == month:
            totals["rows"] += 1
            totals["after"] += cost
            totals[{"Credit": "credit", "Refund": "refund"}.get(kind, "before")] += cost
        # 월 단위 크레딧·환불·정액 비용을 임의로 하루에 배분하지 않는다.
        if kind in ADJUSTMENTS:
            continue
        start = timestamp(row["line_item_usage_start_date"])
        end = timestamp(row["line_item_usage_end_date"])
        if end <= start or end - start > timedelta(hours=1):
            unallocated += 1
            continue
        key = start.astimezone(KST).date().isoformat()
        if key in days:
            boundary = datetime.combine(start.astimezone(KST).date() + timedelta(days=1), time(), KST)
            if end > boundary:
                raise ValueError("CUR interval crosses Korean day boundary")
            days[key]["cost"] += cost
            days[key]["rows"] += 1
            days[key]["services"][usage_category(row)] += cost
    return {"days": days, "month": month, "monthly": totals, "unallocated": unallocated, "row_count": row_count}


def manifest_files(value, bucket, prefix):
    """manifest가 참조한 CSV만 사용한다. 디렉터리 전체를 합쳐 중복 집계하지 않는다."""
    found = set()

    def visit(item):
        if isinstance(item, dict):
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
        elif isinstance(item, str) and item.endswith(".csv.gz"):
            key = item
            if key.startswith("s3://"):
                parsed = urllib.parse.urlsplit(key)
                if parsed.netloc != bucket:
                    raise ValueError("Manifest references another bucket")
                key = parsed.path.lstrip("/")
            if not key.startswith(prefix + "/data/") or ".." in key.split("/"):
                raise ValueError("Unexpected manifest data path")
            found.add(key)

    visit(value)
    if not found:
        raise ValueError("Manifest has no CSV data files")
    if len(found) > 100:
        raise ValueError("Export exceeds daily reader file limit")
    return sorted(found)


def load_reports(s3, bucket, export_name, now):
    prefix = f"cur/{export_name}"
    manifests = []
    missing = []
    files = []
    for month in required_months(now):
        metadata = f"{prefix}/metadata/BILLING_PERIOD={month}/"
        candidates = []
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=metadata):
            for obj in page.get("Contents", []):
                # 실행별 하위 manifest와 최신 고정 manifest를 동시에 읽지 않는다.
                tail = obj["Key"][len(metadata):]
                if "/" not in tail and tail.lower().endswith("manifest.json"):
                    candidates.append(obj)
        if not candidates:
            missing.append(month)
            continue
        latest = max(candidates, key=lambda obj: obj["LastModified"])
        with s3.get_object(Bucket=bucket, Key=latest["Key"])["Body"] as body:
            manifest = json.loads(body.read(2 * 1024 * 1024))
        keys = manifest_files(manifest, bucket, prefix)
        files.extend(keys)
        manifests.append({"month": month, "updated": latest["LastModified"]})
    return iter_csv_rows(s3, bucket, files), manifests, missing


def iter_csv_rows(s3, bucket, files):
    total_bytes = 0
    row_count = 0
    for key in files:
        response = s3.get_object(Bucket=bucket, Key=key)
        with response["Body"] as body:
            total_bytes += response["ContentLength"]
            if total_bytes > 64 * 1024 * 1024:
                raise ValueError("Export exceeds daily reader compressed size limit")
            with gzip.GzipFile(fileobj=body) as compressed:
                text = io.TextIOWrapper(compressed, encoding="utf-8-sig", newline="")
                for row in csv.DictReader(text):
                    row_count += 1
                    if row_count > 200000:
                        raise ValueError("Export exceeds daily reader row limit")
                    yield row


def money(amount):
    rounded = amount.quantize(Decimal("0.01"))
    if rounded == ZERO:
        rounded = ZERO
    return f"${rounded:,.2f}"


def render(result, manifests, missing, now):
    lines = ["*DevOops AWS 일일 비용 — 잠정 집계*",
             f"조회: {now.astimezone(KST):%Y-%m-%d %H:%M} KST / 프로젝트 계정만 집계",
             "*한국 시간 00:00~24:00 / 크레딧·환불 전 시간별 비용*"]
    for index, (day, item) in enumerate(result["days"].items()):
        label = "전날" if index == 0 else "재집계"
        value = money(item["cost"]) if item["rows"] else "아직 집계된 행 없음 (0달러 확정 아님)"
        lines.append(f"• {day} ({label}): {value}")
        if index == 0 and item["rows"]:
            details = sorted(item["services"].items(), key=lambda pair: (-pair[1], pair[0]))
            lines.append("  전날 비용 상세 (0이 아닌 항목 전체):")
            for name, cost in details:
                if cost != ZERO:
                    amount = money(cost) if abs(cost) >= Decimal("0.01") else (
                        "-$0.01 미만" if cost < ZERO else "$0.01 미만")
                    lines.append(f"    • {name}: {amount}")
    totals = result["monthly"]
    lines.append(f"*{result['month']} AWS 청구월 누적 (UTC 청구월 기준)*")
    if totals["rows"]:
        lines.extend([f"• 크레딧·환불 전: {money(totals['before'])}",
                      f"• 크레딧: {money(totals['credit'])} / 환불: {money(totals['refund'])}",
                      f"• 반영 후: {money(totals['after'])}"])
    else:
        lines.append("• 보고서 미수신 또는 집계 행 없음 — 금액 확인 대기")
    if manifests:
        updates = ", ".join(f"{item['month']}: {item['updated'].astimezone(KST):%m/%d %H:%M} KST"
                            for item in manifests)
        lines.append(f"보고서 갱신: {updates}")
        if any(now - item["updated"] > timedelta(hours=36) for item in manifests
               if item["month"] == result["month"]):
            lines.append("주의: 현재 청구월 보고서가 36시간 이상 갱신되지 않았습니다.")
    if missing:
        lines.append("아직 받지 못한 청구월 보고서: " + ", ".join(missing))
    lines.append("AWS 데이터 반영 지연으로 최근 3일 금액은 다음 알림에서 달라질 수 있습니다.")
    lines.append("월 단위·시간 미지정 비용은 일별 금액에서 제외하고 청구월 합계에 포함합니다. "
                 "크레딧·환불도 하루에 임의 배분하지 않습니다. 합계는 확정 청구서가 아닙니다.")
    return "\n".join(lines)


def post_slack(url, text):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or parsed.netloc != "hooks.slack.com"
            or not parsed.path.startswith("/services/") or parsed.query or parsed.fragment):
        raise ValueError("Invalid Slack webhook configuration")
    request = urllib.request.Request(url, data=json.dumps({"text": text}, ensure_ascii=False).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status != 200 or response.read(100).strip() != b"ok":
                raise RuntimeError("Slack rejected daily report")
    except (urllib.error.URLError, TimeoutError):
        # 예외의 URL/응답에는 비밀값이 포함될 수 있어 원본을 로그에 남기지 않는다.
        raise RuntimeError("Slack delivery failed; inspect channel and retry manually") from None


def handler(event, context):
    now = datetime.now(UTC)
    s3 = boto3.client("s3", config=SDK_CONFIG)
    rows, manifests, missing = load_reports(s3, os.environ["COST_BUCKET"], os.environ["EXPORT_NAME"], now)
    result = aggregate(rows, os.environ["ACCOUNT_ID"], now)
    text = render(result, manifests, missing, now)
    if event.get("dry_run") is True:
        return {"sent": False, "text": text, "row_count": result["row_count"]}
    ssm = boto3.client("ssm", config=SDK_CONFIG)
    url = ssm.get_parameter(Name=os.environ["WEBHOOK_PARAMETER"], WithDecryption=True)["Parameter"]["Value"]
    post_slack(url, text)
    return {"sent": True, "row_count": result["row_count"], "missing_months": missing}
