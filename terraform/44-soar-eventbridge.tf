# ---------------------------------------------------------------------------
# EventBridge: the decision-to-action boundary (REQ-NCA-P2-06)
#
# The rule engine does not call the action functions. It publishes an event
# describing what should happen, and EventBridge routes it. Consequences:
#
#   - adding a fourth response action means adding a rule, not editing the
#     engine
#   - one action failing cannot stop the others from running
#   - every dispatch is independently retried and independently observable
#
# This is what makes the architecture event-driven rather than a chain of
# function calls wearing an event-driven label.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_bus" "soar" {
  name = "${var.project}-soar"
  tags = { Component = "soar" }
}

# Archive every dispatched action for replay during incident review.
resource "aws_cloudwatch_event_archive" "soar" {
  name             = "${var.project}-soar-archive"
  event_source_arn = aws_cloudwatch_event_bus.soar.arn
  retention_days   = 30
  description      = "Replayable record of every SOAR action dispatch"
}

locals {
  soar_action_targets = {
    block_ip = {
      detail_type = "soar.action.block_ip"
      arn         = aws_lambda_function.action_block_ip.arn
      name        = aws_lambda_function.action_block_ip.function_name
    }
    quarantine_host = {
      detail_type = "soar.action.quarantine_host"
      arn         = aws_lambda_function.action_quarantine.arn
      name        = aws_lambda_function.action_quarantine.function_name
    }
    notify = {
      detail_type = "soar.action.notify"
      arn         = aws_lambda_function.action_notify.arn
      name        = aws_lambda_function.action_notify.function_name
    }
  }
}

resource "aws_cloudwatch_event_rule" "soar_action" {
  for_each = local.soar_action_targets

  name           = "${var.project}-soar-${replace(each.key, "_", "-")}"
  description    = "Route ${each.value.detail_type} to its handler"
  event_bus_name = aws_cloudwatch_event_bus.soar.name

  event_pattern = jsonencode({
    source        = ["innovatech.soar"]
    "detail-type" = [each.value.detail_type]
  })

  tags = { Component = "soar" }
}

resource "aws_cloudwatch_event_target" "soar_action" {
  for_each = local.soar_action_targets

  rule           = aws_cloudwatch_event_rule.soar_action[each.key].name
  event_bus_name = aws_cloudwatch_event_bus.soar.name
  target_id      = each.key
  arn            = each.value.arn

  retry_policy {
    maximum_event_age_in_seconds = 300
    maximum_retry_attempts       = 2
  }

  dead_letter_config {
    arn = aws_sqs_queue.soar_action_dlq.arn
  }
}

resource "aws_lambda_permission" "soar_action" {
  for_each = local.soar_action_targets

  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = each.value.name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.soar_action[each.key].arn
}

# An action that could not be delivered is a silent failure of the whole
# system, so it is captured rather than dropped.
resource "aws_sqs_queue" "soar_action_dlq" {
  name                      = "${var.project}-soar-action-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = { Name = "${var.project}-soar-action-dlq" }
}

resource "aws_sqs_queue_policy" "soar_action_dlq" {
  queue_url = aws_sqs_queue.soar_action_dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.soar_action_dlq.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = [for r in aws_cloudwatch_event_rule.soar_action : r.arn]
        }
      }
    }]
  })
}

# --- Scheduled expiry of temporary blocks -----------------------------------

resource "aws_cloudwatch_event_rule" "block_expiry" {
  name                = "${var.project}-soar-block-expiry"
  description         = "Lift IP blocks whose duration has elapsed"
  schedule_expression = "rate(5 minutes)"
  tags                = { Component = "soar" }
}

resource "aws_cloudwatch_event_target" "block_expiry" {
  rule      = aws_cloudwatch_event_rule.block_expiry.name
  target_id = "block-expiry"
  arn       = aws_lambda_function.block_expiry.arn
}

resource "aws_lambda_permission" "block_expiry" {
  statement_id  = "AllowScheduledExpiry"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.block_expiry.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.block_expiry.arn
}
