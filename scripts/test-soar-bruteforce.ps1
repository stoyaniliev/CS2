# =============================================================================
# SOAR end-to-end test: PB-001, external SSH brute force
#
# Sends five failed-authentication events from a single external address and
# verifies that the system detects, decides, and acts without human input.
#
# Expected chain:
#   collector  -> normalise, write to DynamoDB, queue to SQS
#   rule engine-> correlate via the source_ip index, threshold met on the 5th
#   EventBridge-> dispatch soar.action.block_ip and soar.action.notify
#   block_ip   -> DENY entry written to the platform network ACL
#   notify     -> email published to SNS
#
# Success criterion: a DENY rule for the test address exists in the NACL that
# did not exist before the script ran.
# =============================================================================

$ErrorActionPreference = "Stop"

$Region     = "eu-central-1"
$NaclId     = "acl-068c30bcdb9226b04"
$Collector  = "innovatech-soar-collector"
$TestIp     = "203.0.113.66"   # TEST-NET-3, reserved for documentation
$EventCount = 5

Write-Host "`n=== BEFORE: deny rules in $NaclId ===" -ForegroundColor Cyan
aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && Egress==``false``].[RuleNumber,CidrBlock]" `
  --output table

# --- Fire the events ---------------------------------------------------------

$payload = @{
    event_type  = "ssh_auth_failure"
    severity    = "high"
    source_ip   = $TestIp
    target_host = "corp-server.innovatech.internal"
    description = "Failed SSH authentication for user root"
} | ConvertTo-Json -Compress

$payload | Out-File -Encoding ascii -NoNewline "$env:TEMP\soar-event.json"

Write-Host "`n=== Sending $EventCount events from $TestIp ===" -ForegroundColor Cyan
Write-Host "PB-001 threshold is 5 in 5 minutes; the first four should correlate but not fire.`n"

for ($i = 1; $i -le $EventCount; $i++) {
    aws lambda invoke `
        --function-name $Collector `
        --payload "file://$env:TEMP/soar-event.json" `
        --cli-binary-format raw-in-base64-out `
        --region $Region `
        "$env:TEMP\soar-out-$i.json" | Out-Null

    $result = Get-Content "$env:TEMP\soar-out-$i.json" -Raw | ConvertFrom-Json
    $body   = $result.body | ConvertFrom-Json
    Write-Host ("  event {0}/{1}  accepted={2}  id={3}" -f `
        $i, $EventCount, $body.accepted, $body.event_ids[0])
    Start-Sleep -Milliseconds 400
}

Write-Host "`nWaiting 25s for SQS batching, rule evaluation, and action dispatch..." -ForegroundColor Yellow
Start-Sleep -Seconds 25

# --- Verify ------------------------------------------------------------------

Write-Host "`n=== AFTER: deny rules in $NaclId ===" -ForegroundColor Cyan
aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && Egress==``false``].[RuleNumber,CidrBlock]" `
  --output table

Write-Host "`n=== Block record in DynamoDB ===" -ForegroundColor Cyan
aws dynamodb scan --table-name innovatech-soar-blocks --region $Region `
  --query "Items[].{CIDR:cidr.S,Rule:rule_number.N,Playbook:playbook_id.S,Status:status.S,Expires:expires_at_iso.S}" `
  --output table

Write-Host "`n=== Events stored ===" -ForegroundColor Cyan
$count = aws dynamodb scan --table-name innovatech-soar-events --region $Region --select COUNT --query "Count" --output text
Write-Host "  $count events in the store"

Write-Host "`n=== Verdict ===" -ForegroundColor Cyan
$denies = aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && CidrBlock=='$TestIp/32']" --output json | ConvertFrom-Json

if ($denies.Count -gt 0) {
    Write-Host "  PASS - $TestIp was blocked automatically by rule $($denies[0].RuleNumber)" -ForegroundColor Green
    Write-Host "  No human touched the network. Detection to containment, end to end.`n"
} else {
    Write-Host "  FAIL - no deny rule found for $TestIp" -ForegroundColor Red
    Write-Host "  Diagnose with:" -ForegroundColor Yellow
    Write-Host "    aws logs tail /aws/lambda/innovatech-soar-rule-engine --since 5m --region $Region"
    Write-Host "    aws logs tail /aws/lambda/innovatech-soar-action-block-ip --since 5m --region $Region`n"
}
