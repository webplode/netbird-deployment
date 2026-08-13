#!/usr/bin/env python3
"""Generate S3 presigned URLs for the migration data copy.

Run via uv so boto3 does not need a global install:
    uv run --with boto3 python presign.py put <bucket> <key> [--expires 3600] [--profile P] [--region R]
    uv run --with boto3 python presign.py get <bucket> <key> [--expires 3600] [--profile P] [--region R]

PUT URLs let the old host upload with plain curl -T (no AWS credentials on the
host). GET URLs let the new host download with plain curl (no widening of its
instance role). Objects are server-side encrypted by the bucket default.
"""
import argparse
import sys

import boto3
from botocore.config import Config


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("method", choices=["put", "get"])
    parser.add_argument("bucket")
    parser.add_argument("key")
    parser.add_argument("--expires", type=int, default=3600)
    parser.add_argument("--profile", default=None)
    parser.add_argument("--region", default="ap-southeast-1")
    args = parser.parse_args()

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    client = session.client("s3", config=Config(signature_version="s3v4"))
    operation = "put_object" if args.method == "put" else "get_object"
    url = client.generate_presigned_url(
        operation,
        Params={"Bucket": args.bucket, "Key": args.key},
        ExpiresIn=args.expires,
        HttpMethod="PUT" if args.method == "put" else "GET",
    )
    sys.stdout.write(url)


if __name__ == "__main__":
    main()
