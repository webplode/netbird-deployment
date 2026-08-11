terraform {
  # Supply the bucket, key, region, and lock-file settings at init time. Keeping
  # them out of source lets each AWS account own its state location.
  backend "s3" {}
}
