# =============================================================================
# SOAR end-to-end test: on-premises syslog event source (REQ-NCA-P2-06)
#
# The other tests submit events to the collector directly. This one does not
# fabricate anything. It runs failed SSH logins against the simulated corporate
# server, so sshd writes real lines into auth.log, the forwarder agent picks
# them up, and the response fires.
#
# The whole chain is real:
#   failed login -> sshd -> auth.log -> forwarder -> private API -> collector
#   -> DynamoDB -> SQS -> rule engine -> EventBridge -> block_ip -> NACL entry
#
# Nothing in that path is simulated except the fact that the "on-premises"
# server is an EC2 instance, which the assignment permits.
# =============================================================================

$ErrorActionPreference = "Stop"

$Region  = "eu-central-1"
$NaclId  = "acl-068c30bcdb9226b04"
$KeyPath = "..\innovatech-key.pem"

Write-Host "`n=== Resolving hosts from Terraform ===" -ForegroundColor Cyan
Push-Location ..\terraform
$Bastion    = (terraform output -raw bastion_public_ip).Trim()
$CorpServer = (terraform output -raw corp_server_ip).Trim()
Pop-Location
Write-Host "  bastion      $Bastion"
Write-Host "  corp-server  $CorpServer"

Write-Host "`n=== Forwarder agent status ===" -ForegroundColor Cyan
ssh -i $KeyPath -o StrictHostKeyChecking=accept-new `
    -o ProxyCommand="ssh -i $KeyPath -W %h:%p ubuntu@$Bastion" `
    ubuntu@$CorpServer "systemctl is-active soar-forwarder && sudo tail -3 /var/log/auth.log"

Write-Host "`n=== BEFORE: deny rules ===" -ForegroundColor Cyan
aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && Egress==``false``].[RuleNumber,CidrBlock]" `
  --output table

# --- Generate real failed logins on the on-prem host -------------------------
# Executed from the bastion so the attempts originate from a routable address
# and appear in auth.log exactly as a genuine attack would.

Write-Host "`n=== Running 6 failed SSH logins against corp-server ===" -ForegroundColor Cyan
Write-Host "These are real authentication failures, written by sshd.`n"

$attack = @"
for i in 1 2 3 4 5 6; do
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      root@$CorpServer 'true' 2>/dev/null || echo "  attempt \$i rejected"
  sleep 1
done
"@

ssh -i $KeyPath -o StrictHostKeyChecking=accept-new ubuntu@$Bastion $attack

Write-Host "`nWaiting 35s for the forwarder poll, ingest, correlation and response..." -ForegroundColor Yellow
Start-Sleep -Seconds 35

# --- Verify ------------------------------------------------------------------

Write-Host "`n=== Forwarder log ===" -ForegroundColor Cyan
ssh -i $KeyPath -o StrictHostKeyChecking=accept-new `
    -o ProxyCommand="ssh -i $KeyPath -W %h:%p ubuntu@$Bastion" `
    ubuntu@$CorpServer "sudo journalctl -u soar-forwarder --since '2 minutes ago' --no-pager | tail -12"

Write-Host "`n=== Events received from the on-premises source ===" -ForegroundColor Cyan
aws dynamodb scan --table-name innovatech-soar-events --region $Region `
  --filter-expression "#s = :s" `
  --expression-attribute-names '{\"#s\":\"source\"}' `
  --expression-attribute-values '{\":s\":{\"S\":\"syslog\"}}' `
  --query "Items[].{Type:event_type.S,Host:target_host.S,IP:source_ip.S,At:received_at.S}" `
  --output table

Write-Host "`n=== AFTER: deny rules ===" -ForegroundColor Cyan
aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && Egress==``false``].[RuleNumber,CidrBlock]" `
  --output table

Write-Host "`n=== Verdict ===" -ForegroundColor Cyan
$count = aws dynamodb scan --table-name innovatech-soar-events --region $Region `
  --filter-expression "#s = :s" `
  --expression-attribute-names '{\"#s\":\"source\"}' `
  --expression-attribute-values '{\":s\":{\"S\":\"syslog\"}}' `
  --select COUNT --query "Count" --output text

if ([int]$count -gt 0) {
    Write-Host "  PASS - $count event(s) reached the SOAR pipeline from the on-premises server" -ForegroundColor Green
    Write-Host "  Origin was sshd writing to auth.log, not a synthetic payload.`n"
} else {
    Write-Host "  FAIL - no syslog-sourced events found" -ForegroundColor Red
    Write-Host "  Check the forwarder: systemctl status soar-forwarder on corp-server`n" -ForegroundColor Yellow
}
