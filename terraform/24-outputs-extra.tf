# Consumed by the SOAR block_ip Lambda: the ACL guarding the platform spoke.
output "platform_nacl_id" {
  value = module.platform_spoke.default_network_acl_id
}

output "quarantine_sg_id" {
  value = aws_security_group.quarantine.id
}

output "events_table" {
  value = aws_dynamodb_table.events.name
}

output "ingest_queue_url" {
  value = aws_sqs_queue.soar_ingest.url
}
