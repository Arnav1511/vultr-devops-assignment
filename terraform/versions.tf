terraform {
  # 1.10+ is required for `use_lockfile` (S3-native state locking) in backend.tf.
  required_version = ">= 1.10"

  required_providers {
    vultr = {
      source = "vultr/vultr"
      # Pessimistic pin: take 2.x bug fixes, never a 3.0 with breaking changes.
      # The exact version is recorded in .terraform.lock.hcl, which is committed.
      version = "~> 2.33"
    }
  }
}

# The API key is read from the VULTR_API_KEY environment variable, so it never
# appears in a .tf or .tfvars file and cannot be committed by accident.
provider "vultr" {
  # Stay under Vultr's API rate limit; without this, applies intermittently 429.
  rate_limit  = 100
  retry_limit = 3
}
