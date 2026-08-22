# ---------------------------------------------------------------------------
# SOAR Lambda functions (REQ-NCA-P2-07: serverless where appropriate)
#
# "Where appropriate" means: work that is bursty, short-lived, and event-driven.
# Security alerts arrive unpredictably — nothing for an hour, then forty in a
# minute during an attack. Holding a VM idle for that pattern wastes money and
# still fails to absorb the burst. Lambda scales to the burst and costs nothing
# between events.
#
# The functions run OUTSIDE the VPC on purpose. They call only AWS APIs, never
# resources inside a subnet, so VPC attachment would add ENI cold-start latency
# and a NAT dependency for no security gain.
# ---------------------------------------------------------------------------

data "archive_file" "collector" {
  type        = "zip"
  source_dir  = "${path.module}/../soar/collector"
  output_path = "${path.module}/.build/collector.zip"
}

# The rule engine ships with its playbooks, so the deployed artefact and the
# rules it enforces are versioned together and can never drift apart.
data "archive_file" "rule_engine" {
  type        = "zip"
  output_path = "${path.module}/.build/rule-engine.zip"

  source {
    content  = file("${path.module}/../soar/rule-engine/handler.py")
    filename = "handler.py"
  }
  source {
    content  = file("${path.module}/../soar/playbooks/playbooks.json")
    filename = "playbooks.json"
  }
}

data "archive_file" "action_block_ip" {
  type        = "zip"
  output_path = "${path.module}/.build/action-block-ip.zip"
  source {
    content  = file("${path.module}/../soar/actions/block_ip/handler.py")
    filename = "handler.py"
  }
}

data "archive_file" "block_expiry" {
  type        = "zip"
  output_path = "${path.module}/.build/block-expiry.zip"
  source {
    content  = file("${path.module}/../soar/actions/block_ip/expire.py")
    filename = "expire.py"
  }
}

data "archive_file" "action_quarantine" {
  type        = "zip"
  source_dir  = "${path.module}/../soar/actions/quarantine_host"
  output_path = "${path.module}/.build/action-quarantine-host.zip"
}

data "archive_file" "action_notify" {
  type        = "zip"
  source_dir  = "${path.module}/../soar/actions/notify"
  output_path = "${path.module}/.build/action-notify.zip"
}

# --- Functions --------------------------------------------------------------

resource "aws_lambda_function" "collector" {
  function_name    = "${var.project}-soar-collector"
  role             = aws_iam_role.soar["collector"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.collector.output_path
  source_code_hash = data.archive_file.collector.output_base64sha256

  environment {
    variables = {
      EVENTS_TABLE     = aws_dynamodb_table.events.name
      INGEST_QUEUE_URL = aws_sqs_queue.soar_ingest.url
      EVENT_TTL_DAYS   = "30"
    }
  }

  tags = { Component = "soar", Stage = "ingest" }
}

resource "aws_lambda_function" "rule_engine" {
  function_name    = "${var.project}-soar-rule-engine"
  role             = aws_iam_role.soar["rule-engine"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.rule_engine.output_path
  source_code_hash = data.archive_file.rule_engine.output_base64sha256

  environment {
    variables = {
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.soar.name
      EVENTS_TABLE   = aws_dynamodb_table.events.name
      PLAYBOOK_PATH  = "playbooks.json"
    }
  }

  tags = { Component = "soar", Stage = "decide" }
}

resource "aws_lambda_function" "action_block_ip" {
  function_name    = "${var.project}-soar-action-block-ip"
  role             = aws_iam_role.soar["action-block-ip"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.action_block_ip.output_path
  source_code_hash = data.archive_file.action_block_ip.output_base64sha256

  environment {
    variables = {
      PLATFORM_NACL_ID = module.platform_spoke.default_network_acl_id
      BLOCKS_TABLE     = aws_dynamodb_table.blocks.name
    }
  }

  tags = { Component = "soar", Stage = "respond" }
}

resource "aws_lambda_function" "action_quarantine" {
  function_name    = "${var.project}-soar-action-quarantine-host"
  role             = aws_iam_role.soar["action-quarantine-host"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.action_quarantine.output_path
  source_code_hash = data.archive_file.action_quarantine.output_base64sha256

  environment {
    variables = {
      QUARANTINE_SG_ID = aws_security_group.quarantine.id
      QUARANTINE_TABLE = aws_dynamodb_table.quarantines.name
    }
  }

  tags = { Component = "soar", Stage = "respond" }
}

resource "aws_lambda_function" "action_notify" {
  function_name    = "${var.project}-soar-action-notify"
  role             = aws_iam_role.soar["action-notify"].arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.action_notify.output_path
  source_code_hash = data.archive_file.action_notify.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.soar_notify.arn
    }
  }

  tags = { Component = "soar", Stage = "respond" }
}

resource "aws_lambda_function" "block_expiry" {
  function_name    = "${var.project}-soar-block-expiry"
  role             = aws_iam_role.soar["block-expiry"].arn
  handler          = "expire.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 128
  filename         = data.archive_file.block_expiry.output_path
  source_code_hash = data.archive_file.block_expiry.output_base64sha256

  environment {
    variables = {
      BLOCKS_TABLE = aws_dynamodb_table.blocks.name
    }
  }

  tags = { Component = "soar", Stage = "maintenance" }
}

# --- Log groups, declared so retention is managed rather than infinite ------

resource "aws_cloudwatch_log_group" "soar" {
  for_each = {
    collector   = aws_lambda_function.collector.function_name
    rule_engine = aws_lambda_function.rule_engine.function_name
    block_ip    = aws_lambda_function.action_block_ip.function_name
    quarantine  = aws_lambda_function.action_quarantine.function_name
    notify      = aws_lambda_function.action_notify.function_name
    expiry      = aws_lambda_function.block_expiry.function_name
  }

  name              = "/aws/lambda/${each.value}"
  retention_in_days = 14
  tags              = { Component = "soar" }
}

# --- Queue -> rule engine ---------------------------------------------------

resource "aws_lambda_event_source_mapping" "rule_engine" {
  event_source_arn = aws_sqs_queue.soar_ingest.arn
  function_name    = aws_lambda_function.rule_engine.arn
  batch_size       = 10

  # Waits briefly for a full batch instead of invoking per message.
  maximum_batching_window_in_seconds = 5

  # Only genuinely failed messages are retried; one bad event no longer causes
  # the whole batch to be redelivered.
  function_response_types = ["ReportBatchItemFailures"]
}
