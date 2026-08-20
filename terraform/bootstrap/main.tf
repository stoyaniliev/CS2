# ---------------------------------------------------------------------------
# Bootstrap: remote Terraform state.
#
# Run ONCE, with local state, before anything else. Everything after this
# keeps its state in S3 so an account wipe or a laptop failure never costs
# more than a `terraform apply`.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "innovatech-cs2"
      ManagedBy = "terraform"
      Layer     = "bootstrap"
    }
  }
}

variable "region" {
  description = "AWS region. Frankfurt keeps Innovatech's data inside the EU."
  type        = string
  default     = "eu-central-1"
}

# Bucket names are globally unique; a suffix avoids collisions.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "state" {
  bucket = "innovatech-cs2-tfstate-${random_id.suffix.hex}"

  # Deliberate: protects against a stray `terraform destroy` in this layer
  # taking the state of every other layer with it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State locking: stops a local run and a pipeline run corrupting each other.
resource "aws_dynamodb_table" "lock" {
  name         = "innovatech-cs2-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket" {
  description = "Paste this into terraform/backend.tf"
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "backend_config" {
  description = "Ready-made backend block."
  value       = <<-EOT

    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.id}"
        key            = "innovatech/main.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.lock.name}"
        encrypt        = true
      }
    }
  EOT
}
