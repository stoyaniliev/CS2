# Notification channel for the SOAR "notify" response action.
resource "aws_sns_topic" "soar_notify" {
  name = "${var.project}-soar-notifications"
  tags = { Name = "${var.project}-soar-notifications" }
}

resource "aws_sns_topic_subscription" "soar_email" {
  topic_arn = aws_sns_topic.soar_notify.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

output "sns_topic_arn" {
  value = aws_sns_topic.soar_notify.arn
}

output "sns_confirm_note" {
  value = "Check ${var.alert_email} and confirm the SNS subscription, or notifications will not arrive."
}
