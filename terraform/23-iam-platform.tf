# ---------------------------------------------------------------------------
# IAM for the platform (REQ: least privilege)
#
# CS3 could not do this — the Learner Lab account denied iam:CreateRole and
# everything ran as the shared LabRole. This account permits role creation, so
# each component now gets a role scoped to what it actually needs.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "k3s" {
  name               = "${var.project}-k3s-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${var.project}-k3s-node" }
}

resource "aws_iam_instance_profile" "k3s" {
  name = "${var.project}-k3s-node"
  role = aws_iam_role.k3s.name
}

data "aws_iam_policy_document" "k3s" {
  # Pull SOAR container images.
  statement {
    sid    = "EcrPull"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = ["*"] # GetAuthorizationToken does not accept a resource scope
  }

  # Publish alerts into the SOAR ingest queue. Write only — the cluster has no
  # business reading or deleting from the event pipeline.
  statement {
    sid       = "SoarIngest"
    effect    = "Allow"
    actions   = ["sqs:SendMessage", "sqs:GetQueueUrl"]
    resources = [aws_sqs_queue.soar_ingest.arn]
  }

  # Publish its own metrics; the namespace condition stops it writing anywhere else.
  statement {
    sid       = "PublishMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Innovatech/SOAR", "Innovatech/Platform"]
    }
  }

  # Read CloudWatch so cloudwatch-exporter can scrape Lambda metrics into
  # Prometheus for the SOAR operations dashboard (REQ-NCA-P2-08).
  statement {
    sid    = "ReadCloudWatch"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  # Long-term observability storage. Loki writes chunks and the Prometheus
  # sidecar writes metric blocks here; scoped to this one bucket.
  statement {
    sid    = "ObservabilityBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts",
    ]
    resources = [
      aws_s3_bucket.observability.arn,
      "${aws_s3_bucket.observability.arn}/*",
    ]
  }

  # Read-only access to the SOAR event store, so Grafana can display incident
  # history. The cluster must not be able to alter the audit record.
  statement {
    sid    = "ReadSoarState"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:DescribeTable",
    ]
    resources = [
      aws_dynamodb_table.events.arn,
      "${aws_dynamodb_table.events.arn}/index/*",
      aws_dynamodb_table.blocks.arn,
      aws_dynamodb_table.quarantines.arn,
    ]
  }
}

resource "aws_iam_role_policy" "k3s" {
  name   = "${var.project}-k3s-node-policy"
  role   = aws_iam_role.k3s.id
  policy = data.aws_iam_policy_document.k3s.json
}

# Session Manager access, so a lost SSH key never means a lost cluster.
resource "aws_iam_role_policy_attachment" "k3s_ssm" {
  role       = aws_iam_role.k3s.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
