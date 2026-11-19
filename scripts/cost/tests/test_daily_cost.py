import gzip
import io
import json
import sys
import unittest
from datetime import datetime, timedelta
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch
from urllib.error import URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import daily_cost as cost

ACCOUNT = "123456789012"
NOW = datetime(2026, 11, 19, 0, tzinfo=cost.UTC)


def row(start="2026-11-18T15:00:00Z", end="2026-11-18T16:00:00Z", amount="1.25", **extra):
    result = dict(bill_billing_period_start_date="2026-11-01T00:00:00Z",
                  line_item_usage_account_id=ACCOUNT, line_item_currency_code="USD",
                  line_item_line_item_type="Usage", line_item_usage_start_date=start,
                  line_item_usage_end_date=end, line_item_unblended_cost=amount,
                  line_item_net_unblended_cost="", line_item_product_code="AmazonEC2")
    result.update(extra)
    return result


class CostTests(unittest.TestCase):
    def test_korean_midnight_boundaries(self):
        rows = [row("2026-11-17T15:00:00Z", "2026-11-17T16:00:00Z", "2"),
                row("2026-11-18T14:00:00Z", "2026-11-18T15:00:00Z", "3"), row()]
        result = cost.aggregate(rows, ACCOUNT, NOW)
        self.assertEqual(result["days"]["2026-11-18"]["cost"], Decimal("5"))
        self.assertEqual(result["days"]["2026-11-18"]["rows"], 2)

    def test_other_accounts_excluded_even_if_export_is_misconfigured(self):
        result = cost.aggregate([row(line_item_usage_account_id="999999999999")], ACCOUNT, NOW)
        self.assertEqual(result["monthly"]["rows"], 0)

    def test_credit_refund_and_monthly_fee_not_allocated_to_one_day(self):
        rows = [row("2026-11-18T00:00:00Z", "2026-11-18T01:00:00Z", "4"),
                row(amount="-2", line_item_line_item_type="Credit"),
                row(amount="-1", line_item_line_item_type="Refund"),
                row("2026-11-01T00:00:00Z", "2026-12-01T00:00:00Z", "6", line_item_line_item_type="Fee")]
        result = cost.aggregate(rows, ACCOUNT, NOW)
        self.assertEqual(result["monthly"]["before"], Decimal("10"))
        self.assertEqual(result["monthly"]["after"], Decimal("7"))
        self.assertEqual(result["days"]["2026-11-18"]["cost"], Decimal("4"))
        self.assertEqual(result["unallocated"], 1)

    def test_net_discount_and_decimal_precision(self):
        result = cost.aggregate([row(line_item_net_unblended_cost="0.1"),
                                 row(line_item_net_unblended_cost="0.2")], ACCOUNT, NOW)
        self.assertEqual(result["monthly"]["before"], Decimal("0.3"))

    def test_month_boundary_reads_both_utc_partitions(self):
        now = datetime(2026, 12, 2, 0, tzinfo=cost.UTC)
        self.assertEqual(cost.required_months(now), ["2026-11", "2026-12"])

    def test_missing_data_is_not_announced_as_zero_spend(self):
        result = cost.aggregate([], ACCOUNT, NOW)
        text = cost.render(result, [], ["2026-11"], NOW)
        self.assertIn("0달러 확정 아님", text)
        self.assertNotIn("전날): $0.00", text)
        self.assertIn("보고서 미수신", text)

    def test_future_day_is_excluded_but_kept_in_billing_month(self):
        result = cost.aggregate([row()], ACCOUNT, NOW)
        self.assertEqual(result["days"]["2026-11-18"]["rows"], 0)
        self.assertEqual(result["monthly"]["before"], Decimal("1.25"))

    def test_manifest_deduplicates_and_rejects_other_buckets(self):
        path = "cur/export/data/BILLING_PERIOD=2026-11/run/part.csv.gz"
        self.assertEqual(cost.manifest_files({"files": [path, path]}, "bucket", "cur/export"), [path])
        with self.assertRaises(ValueError):
            cost.manifest_files({"files": ["s3://other/" + path]}, "bucket", "cur/export")
        with self.assertRaises(ValueError):
            cost.manifest_files({"files": ["cur/other/data/part.csv.gz"]}, "bucket", "cur/export")

    def test_streaming_csv_closes_body(self):
        fields = list(row())
        csv_text = ",".join(fields) + "\n" + ",".join(row()[key] for key in fields) + "\n"
        body = io.BytesIO(gzip.compress(csv_text.encode()))

        class S3:
            def get_object(self, **kwargs):
                return {"ContentLength": len(body.getvalue()), "Body": body}

        self.assertEqual(len(list(cost.iter_csv_rows(S3(), "bucket", ["key"]))), 1)
        self.assertTrue(body.closed)

    def test_stale_report_is_visible(self):
        text = cost.render(cost.aggregate([], ACCOUNT, NOW),
                           [{"month": "2026-11", "updated": NOW - timedelta(hours=40)}], [], NOW)
        self.assertIn("36시간 이상", text)

    def test_slack_network_error_does_not_reveal_url(self):
        secret = "https://hooks.slack.com/services/test/secret/value"
        with patch.object(cost.urllib.request, "urlopen", side_effect=URLError(secret)):
            with self.assertRaises(RuntimeError) as raised:
                cost.post_slack(secret, "test")
        self.assertNotIn(secret, str(raised.exception))
        self.assertTrue(raised.exception.__suppress_context__)

    def test_invalid_currency_and_nonfinite_cost_fail_closed(self):
        for invalid in [row(line_item_currency_code="KRW"), row(amount="NaN")]:
            with self.assertRaises(ValueError):
                cost.aggregate([invalid], ACCOUNT, NOW)


if __name__ == "__main__":
    unittest.main()
