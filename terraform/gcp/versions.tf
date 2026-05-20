terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }

  # Remote state lives in a GCS bucket. The bucket is configured via
  # `terraform init -backend-config=...` rather than hardcoded here so that:
  #   1. Different environments (dev/prod) can use different buckets without
  #      changing this file.
  #   2. The bucket name doesn't need to leak the GCP project ID into git.
  #
  # Bootstrap (one-time, per project):
  #   PROJECT_ID="cockroach-ali"
  #   gsutil mb -p "$PROJECT_ID" -l us-central1 -b on \
  #     "gs://${PROJECT_ID}-tfstate-crdb"
  #   gsutil versioning set on "gs://${PROJECT_ID}-tfstate-crdb"
  #
  # Then init this module against it (use a backend config file to avoid
  # passing the bucket name on every command):
  #   make init   # picks up backend.hcl in the repo root
  #
  # Falls back to local state if no backend config is provided (handy for
  # demo/throwaway runs or first-time exploration).
  backend "gcs" {}
}
