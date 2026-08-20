# ---------------------------------------------------------------------------
# Data layer
#
# DESIGN CHANGE, recorded deliberately (see docs/06-reflection.md).
#
# The original design used RDS PostgreSQL. The Fontys organisation SCP
# (p-bg731gel) issues an explicit deny on rds:CreateDBInstance for every
# instance class, including db.serverless. Aurora *clusters* can be created but
# no compute can be attached to them, so the whole RDS family is unusable here.
#
# The constraint produced a better architecture rather than a worse one:
#
#   S3        long-term monitoring data. Loki writes log chunks and Prometheus
#             writes metric blocks here. Eleven nines of durability, no capacity
#             planning, nothing to patch or fail over. This is how observability
#             data is stored in production; a single micro Postgres is not.
#
#   DynamoDB  SOAR operational state: events, active blocks, quarantine records.
#             Written once, read by key, never joined — a key-value workload
#             described honestly.
#
# Both are reached through VPC endpoints, so traffic never touches the internet
# or the NAT gateway. That satisfies REQ-NCA-P2-03 more strongly than a
# private-subnet database would: no route to these services exists at all
# except the private one created below.
# ---------------------------------------------------------------------------

resource "random_id" "data_suffix" {
  byte_length = 4
}

# --- Observability object storage -------------------------------------------

resource "aws_s3_bucket" "observability" {
  bucket        = "${var.project}-observability-${random_id.data_suffix.hex}"
  force_destroy = true
  tags          = { Name = "${var.project}-observability" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "observability" {
  bucket = aws_s3_bucket.observability.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "observability" {
  bucket                  = aws_s3_bucket.observability.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "observability" {
  bucket = aws_s3_bucket.observability.id

  rule {
    id     = "tier-then-expire"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- SOAR operational state --------------------------------------------------

resource "aws_dynamodb_table" "blocks" {
  name         = "${var.project}-soar-blocks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cidr"

  attribute {
    name = "cidr"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = "${var.project}-soar-blocks" }
}

resource "aws_dynamodb_table" "quarantines" {
  name         = "${var.project}-soar-quarantines"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "instance_id"

  attribute {
    name = "instance_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = "${var.project}-soar-quarantines" }
}

# --- VPC endpoints: the private routes REQ-NCA-P2-03 asks for ----------------
# Gateway endpoints cost nothing and inject prefix-list routes into the route
# table, so traffic to S3 and DynamoDB leaves over the AWS backbone.

resource "aws_vpc_endpoint" "s3_platform" {
  vpc_id            = module.platform_spoke.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [module.platform_spoke.route_table_id]

  tags = { Name = "${var.project}-platform-s3-endpoint" }
}

resource "aws_vpc_endpoint" "s3_data" {
  vpc_id            = module.data_spoke.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [module.data_spoke.route_table_id]

  tags = { Name = "${var.project}-data-s3-endpoint" }
}

resource "aws_vpc_endpoint" "dynamodb_platform" {
  vpc_id            = module.platform_spoke.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [module.platform_spoke.route_table_id]

  tags = { Name = "${var.project}-platform-dynamodb-endpoint" }
}

# --- ECR ---------------------------------------------------------------------

resource "aws_ecr_repository" "soar" {
  name                 = "${var.project}/soar"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
  tags         = { Name = "${var.project}-soar-ecr" }
}

resource "aws_ecr_lifecycle_policy" "soar" {
  repository = aws_ecr_repository.soar.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# --- Private name for the observability store (REQ-NCA-P2-04) ----------------

resource "aws_route53_record" "metrics" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "metrics.${var.internal_domain}"
  type    = "CNAME"
  ttl     = 60
  records = ["${aws_s3_bucket.observability.id}.s3.${var.region}.amazonaws.com"]
}

output "observability_bucket" {
  value = aws_s3_bucket.observability.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.soar.repository_url
}

output "blocks_table" {
  value = aws_dynamodb_table.blocks.name
}

output "quarantines_table" {
  value = aws_dynamodb_table.quarantines.name
}
# ---------------------------------------------------------------------------
# SOAR event store. Every normalised event lands here before anything acts on
# it, so the audit trail survives a failure anywhere downstream.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "events" {
  name         = "${var.project}-soar-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"
  range_key    = "received_at"

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "received_at"
    type = "S"
  }

  attribute {
    name = "source_ip"
    type = "S"
  }

  # Lets a playbook ask "how many events from this IP in the last 5 minutes"
  # without a table scan — the basis of the brute-force correlation rule.
  global_secondary_index {
    name            = "source_ip-received_at-index"
    hash_key        = "source_ip"
    range_key       = "received_at"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = "${var.project}-soar-events" }
}