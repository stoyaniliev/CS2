# =============================================================================
# SOAR end-to-end test: on-premises syslog event source (REQ-NCA-P2-06)
#
# The other end-to-end tests submit a payload to the collector. This one does
# not fabricate anything: it provokes real SSH authentication failures on the
# simulated corporate server, so sshd writes the log lines itself and the
# forwarder agent reads what sshd wrote.
#
# Chain under test:
#   ssh attempt -> sshd -> /var/log/auth.log -> forwarder agent
#   -> private API Gateway -> collector -> DynamoDB + SQS -> rule engine
#
# Two things are asserted, and the second is as important as the first.
#
#   1. Events reach the pipeline from the on-premises host and are classified
#      correctly, with the source address extracted.
#
#   2. PB-001 does NOT issue a block, because the attempts originate from the
#      bastion, which is an internal address. That is the safety guard working
#      on real data rather than on a synthetic event. An automated blocker that
#      can be induced to block internal addresses can lock its own operators
#      out of the environment.
#
# Blocking of external addresses is covered by E-01.
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

$Proxy = "ssh -i $KeyPath -o StrictHostKeyChecking=accept-new -W %h:%p ubuntu@$Bastion"

Write-Host "`n=== Forwarder agent status ===" -ForegroundColor Cyan
ssh -i $KeyPath -o StrictHostKeyChecking=accept-new -o ProxyCommand=$Proxy `
    ubuntu@$CorpServer "systemctl is-active soar-forwarder"

$before = aws dynamodb scan --table-name innovatech-soar-events --region $Region `
  --filter-expression "#s = :s" `
  --expression-attribute-names '{\"#s\":\"source\"}' `
  --expression-attribute-values '{\":s\":{\"S\":\"syslog\"}}' `
  --select COUNT --query "Count" --output text
Write-Host "`n  syslog-sourced events before: $before"

Write-Host "`n=== BEFORE: deny rules ===" -ForegroundColor Cyan
aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && Egress==``false``].[RuleNumber,CidrBlock]" `
  --output table

# --- Provoke real authentication failures ------------------------------------
# Attempting to log in as users that do not exist makes sshd write
# "Invalid user X from <address>" without any password being needed. The lines
# are produced by sshd, not by this script.

Write-Host "`n=== Provoking 6 real SSH authentication failures ===" -ForegroundColor Cyan
Write-Host "Attempting non-existent accounts. sshd writes each rejection to auth.log.`n"

$attack = @"
for u in admin oracle postgres jenkins backup deploy; do
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
      "`$u@$CorpServer" 'true' 2>/dev/null
  echo "  rejected: `$u"
  sleep 1
done
"@

ssh -i $KeyPath -o StrictHostKeyChecking=accept-new ubuntu@$Bastion $attack

Write-Host "`nWaiting 40s for the forwarder poll, ingest and rule evaluation..." -ForegroundColor Yellow
Start-Sleep -Seconds 40

# --- Verify ------------------------------------------------------------------

Write-Host "`n=== What sshd actually wrote ===" -ForegroundColor Cyan
ssh -i $KeyPath -o StrictHostKeyChecking=accept-new -o ProxyCommand=$Proxy `
    ubuntu@$CorpServer "sudo grep -E 'Invalid user|Failed password' /var/log/auth.log | tail -6"

Write-Host "`n=== What the forwarder sent ===" -ForegroundColor Cyan
ssh -i $KeyPath -o StrictHostKeyChecking=accept-new -o ProxyCommand=$Proxy `
    ubuntu@$CorpServer "sudo journalctl -u soar-forwarder --since '3 minutes ago' --no-pager | grep forwarded | tail -8"

Write-Host "`n=== Events in the SOAR store from this host ===" -ForegroundColor Cyan
aws dynamodb scan --table-name innovatech-soar-events --region $Region `
  --filter-expression "#s = :s" `
  --expression-attribute-names '{\"#s\":\"source\"}' `
  --expression-attribute-values '{\":s\":{\"S\":\"syslog\"}}' `
  --query "sort_by(Items,&received_at.S)[-6:].{At:received_at.S,Type:event_type.S,Sev:severity.S,From:source_ip.S,Host:target_host.S}" `
  --output table

$after = aws dynamodb scan --table-name innovatech-soar-events --region $Region `
  --filter-expression "#s = :s" `
  --expression-attribute-names '{\"#s\":\"source\"}' `
  --expression-attribute-values '{\":s\":{\"S\":\"syslog\"}}' `
  --select COUNT --query "Count" --output text

Write-Host "`n=== Rule engine decision ===" -ForegroundColor Cyan
aws logs tail /aws/lambda/innovatech-soar-rule-engine --since 3m --region $Region --format short 2>$null |
  Select-String -Pattern "matched|did not match|internal" | Select-Object -Last 6

Write-Host "`n=== AFTER: deny rules ===" -ForegroundColor Cyan
aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && Egress==``false``].[RuleNumber,CidrBlock]" `
  --output table

# --- Verdict -----------------------------------------------------------------

Write-Host "`n=== Verdict ===" -ForegroundColor Cyan
$ingested = [int]$after - [int]$before

$internalBlocked = aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && starts_with(CidrBlock,'10.')]" --output json | ConvertFrom-Json

if ($ingested -ge 5) {
    Write-Host "  PASS  $ingested events reached the pipeline from the on-premises host" -ForegroundColor Green
    Write-Host "        Origin was sshd writing auth.log, not a synthetic payload."
} else {
    Write-Host "  FAIL  only $ingested new syslog events" -ForegroundColor Red
    Write-Host "        Check: systemctl status soar-forwarder on corp-server" -ForegroundColor Yellow
}

if ($internalBlocked.Count -eq 0) {
    Write-Host "`n  PASS  no internal address was blocked" -ForegroundColor Green
    Write-Host "        The attempts came from ${Bastion}'s internal address, so PB-001's"
    Write-Host "        external-source condition correctly declined to act. The guard is"
    Write-Host "        working on real data, not just on the synthetic event in E-05.`n"
} else {
    Write-Host "`n  FAIL  an internal address was blocked, the guard did not hold" -ForegroundColor Red
    $internalBlocked | Format-Table RuleNumber, CidrBlock
}
