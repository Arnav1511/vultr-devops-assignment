# Remote state in Vultr Object Storage (S3-compatible).
#
# Why remote: the state holds the cluster kubeconfig and registry credentials,
# and CI plus any second operator need one shared source of truth. A local
# terraform.tfstate is lost with the laptop.
#
# Chicken-and-egg: Terraform cannot store state in a bucket it has not created
# yet, so the bucket is a manual prerequisite (see docs/setup-guide.md).
#
# Bucket, key and endpoint come from backend.hcl (git-ignored):
#   terraform init -backend-config=backend.hcl
# Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY — the S3
# backend only knows the AWS variable names, even though this is not AWS.
terraform {
  backend "s3" {
    # Not AWS: the backend insists on a region and would otherwise try to
    # validate it, look up an AWS account ID, and query EC2 instance metadata.
    region                      = "us-east-1"
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    # Newer AWS SDKs send checksum headers that non-AWS S3 stores can reject.
    skip_s3_checksum = true
    # Vultr serves buckets at <host>/<bucket>, not <bucket>.<host>.
    use_path_style = true

    # State locking via a .tflock object written with a conditional PUT, so two
    # concurrent applies cannot both write state. Rejected alternative: a
    # DynamoDB lock table, which does not exist on Vultr.
    use_lockfile = true
  }
}
