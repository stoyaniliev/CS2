# ---------------------------------------------------------------------------
# SOAR ingest queue (REQ-NCA-P2-06)
#
# A queue between the collector and the rule engine buys three things:
# alert bursts are absorbed rather than dropped, a failing rule engine cannot
# lose events, and anything that fails repeatedly lands in a dead-letter queue
# where it can be inspected instead of vanishing.
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "soar_ingest_dlq" {
  name                      = "${var.project}-soar-ingest-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
  tags                      = { Name = "${var.project}-soar-ingest-dlq" }
}

resource "aws_sqs_queue" "soar_ingest" {
  name                       = "${var.project}-soar-ingest"
  visibility_timeout_seconds = 180 # >= 6x the rule engine's 30s timeout
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.soar_ingest_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "${var.project}-soar-ingest" }
}

# Depth of the DLQ is a direct health signal for the SOAR system itself.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.project}-soar-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "SOAR events are failing processing and have been parked in the DLQ"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.soar_ingest_dlq.name
  }

  alarm_actions = [aws_sns_topic.soar_notify.arn]
}
