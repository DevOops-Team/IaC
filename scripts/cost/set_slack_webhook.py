"""Webhook을 화면·명령행 인자·파일·Terraform state에 노출하지 않고 SSM에 저장한다."""

import argparse
import getpass
import sys
from urllib.parse import urlsplit

import boto3


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="devoops")
    parser.add_argument("--region", default="us-east-2")
    parser.add_argument("--parameter", default="/devoops/prod/cost/slack-webhook")
    args = parser.parse_args()
    if not sys.stdin.isatty():
        parser.error("Run this command in an interactive terminal")
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    identity = session.client("sts").get_caller_identity()
    print(f"AWS account: {identity['Account']}; parameter: {args.parameter}")
    url = getpass.getpass("Slack Webhook URL (hidden): ").strip()
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.netloc != "hooks.slack.com" or not parsed.path.startswith("/services/"):
        parser.error("Expected an incoming webhook URL from hooks.slack.com")
    response = session.client("ssm").put_parameter(
        Name=args.parameter, Value=url, Type="SecureString", Tier="Standard", Overwrite=True,
        Description="DevOops daily AWS cost report channel webhook")
    print(f"Stored SecureString, version {response['Version']}. Secret value was not printed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
