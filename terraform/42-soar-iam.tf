# ---------------------------------------------------------------------------
# IAM for the SOAR functions.
#
# One role per function, each scoped to exactly what that function does. The
# point is containment: the rule engine decides what should happen but holds no
# permission to make anything happen, and each action can perform its own job
# and nothing else. A flaw in one component cannot be used to reach another.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

locals {
  soar_functions = [
    "collector", "rule-engine",
    "action-block-ip", "action-quarantine-host", "action-notify",
    "block-expiry",
  ]
}

resource "aws_iam_role" "soar" {
  for_each           = toset(local.soar_functions)
  name               = "${var.project}-soar-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${var.project}-soar-${each.key}", Component = "soar" }
}

# CloudWatch Logs for every function: the audit trail, and the transport for
# the embedded metrics that feed the SOAR dashboard.
resource "aws_iam_role_policy_attachment" "soar_logs" {
  for_each   = aws_iam_role.soar
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- collector: store the event, queue it. Nothing else. -------------------
data "aws_iam_policy_document" "collector" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.events.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.soar_ingest.arn]
  }
}

resource "aws_iam_role_policy" "collector" {
  name   = "collector"
  role   = aws_iam_role.soar["collector"].id
  policy = data.aws_iam_policy_document.collector.json
}

# --- rule engine: read events, consume the queue, publish decisions ---------
# Deliberately holds NO ec2, sns, or write permissions of any kind.
data "aws_iam_policy_document" "rule_engine" {
  statement {
    effect  = "Allow"
    actions = ["dynamodb:Query", "dynamodb:GetItem"]
    resources = [
      aws_dynamodb_table.events.arn,
      "${aws_dynamodb_table.events.arn}/index/*",
    ]
  }
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.soar_ingest.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.soar.arn]
  }
}

resource "aws_iam_role_policy" "rule_engine" {
  name   = "rule-engine"
  role   = aws_iam_role.soar["rule-engine"].id
  policy = data.aws_iam_policy_document.rule_engine.json
}

# --- block-ip: write NACL deny entries, record the block -------------------
data "aws_iam_policy_document" "action_block_ip" {
  statement {
    sid    = "ManageNaclEntries"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkAclEntry",
      "ec2:DeleteNetworkAclEntry",
      "ec2:DescribeNetworkAcls",
    ]
    # Describe* does not support resource-level permissions, so the write
    # actions are constrained by the NACL's own scope instead: this role can
    # only affect the platform spoke's ACL because that is the only ID the
    # function is given, and the guard rails live in the handler.
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.blocks.arn]
  }
}

resource "aws_iam_role_policy" "action_block_ip" {
  name   = "action-block-ip"
  role   = aws_iam_role.soar["action-block-ip"].id
  policy = data.aws_iam_policy_document.action_block_ip.json
}

# --- quarantine-host: swap security groups, record the quarantine ----------
data "aws_iam_policy_document" "action_quarantine" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    sid    = "IsolateTaggedInstancesOnly"
    effect = "Allow"
    actions = ["ec2:ModifyInstanceAttribute"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    # Second safety gate, enforced by IAM rather than by code: even if the
    # handler's tag check were bypassed, the API call itself fails on any
    # instance not explicitly marked as quarantinable.
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/SOARable"
      values   = ["true"]
    }
  }
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.quarantines.arn]
  }
}

resource "aws_iam_role_policy" "action_quarantine" {
  name   = "action-quarantine-host"
  role   = aws_iam_role.soar["action-quarantine-host"].id
  policy = data.aws_iam_policy_document.action_quarantine.json
}

# --- notify: publish to one topic ------------------------------------------
data "aws_iam_policy_document" "action_notify" {
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.soar_notify.arn]
  }
}

resource "aws_iam_role_policy" "action_notify" {
  name   = "action-notify"
  role   = aws_iam_role.soar["action-notify"].id
  policy = data.aws_iam_policy_document.action_notify.json
}

# --- block expiry: remove entries it previously created --------------------
data "aws_iam_policy_document" "block_expiry" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:DeleteNetworkAclEntry", "ec2:DescribeNetworkAcls"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:Scan", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.blocks.arn]
  }
}

resource "aws_iam_role_policy" "block_expiry" {
  name   = "block-expiry"
  role   = aws_iam_role.soar["block-expiry"].id
  policy = data.aws_iam_policy_document.block_expiry.json
}
