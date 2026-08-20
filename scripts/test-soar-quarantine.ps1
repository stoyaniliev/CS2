# =============================================================================
# SOAR end-to-end test: PB-002, host compromise indicator
#
# Verifies the second response action. A privilege-escalation event naming the
# demo workstation should cause that instance to be isolated: its security
# groups are replaced with the quarantine group, which has no ingress and no
# egress rules at all.
#
# The instance keeps running so disk and memory forensics remain possible. That
# is the deliberate choice over stopping it, which would destroy volatile
# evidence.
#
# Success criterion: the instance's security group changes to the quarantine
# group, and the original groups are recorded so it can be restored.
# =============================================================================

$ErrorActionPreference = "Stop"

$Region       = "eu-central-1"
$InstanceId   = "i-049e95348a865e18d"   # innovatech-demo-workstation
$QuarantineSg = "sg-0b4ece4aff6a3eebe"
$Collector    = "innovatech-soar-collector"

function Get-Sgs {
    aws ec2 describe-instances --instance-ids $InstanceId --region $Region `
      --query "Reservations[0].Instances[0].SecurityGroups[].GroupId" --output text
}

Write-Host "`n=== BEFORE ===" -ForegroundColor Cyan
$before = Get-Sgs
Write-Host "  security groups: $before"

if ($before -eq $QuarantineSg) {
    Write-Host "`n  Instance is already quarantined. Restore it first:" -ForegroundColor Yellow
    Write-Host "    .\restore-quarantined-host.ps1`n"
    exit 1
}

# --- Fire the event ----------------------------------------------------------

$payload = @{
    event_type         = "privilege_escalation_attempt"
    severity           = "critical"
    source_ip          = "10.1.11.50"
    target_host        = "demo-workstation"
    target_instance_id = $InstanceId
    description        = "Repeated sudo authentication failures followed by an unexpected setuid binary"
} | ConvertTo-Json -Compress

$payload | Out-File -Encoding ascii -NoNewline "$env:TEMP\soar-quarantine.json"

Write-Host "`n=== Sending compromise indicator for $InstanceId ===" -ForegroundColor Cyan
aws lambda invoke `
    --function-name $Collector `
    --payload "file://$env:TEMP/soar-quarantine.json" `
    --cli-binary-format raw-in-base64-out `
    --region $Region `
    "$env:TEMP\soar-quarantine-out.json" | Out-Null

$body = (Get-Content "$env:TEMP\soar-quarantine-out.json" -Raw | ConvertFrom-Json).body | ConvertFrom-Json
Write-Host "  accepted, event id $($body.event_ids[0])"

Write-Host "`nWaiting 25s for evaluation and dispatch..." -ForegroundColor Yellow
Start-Sleep -Seconds 25

# --- Verify ------------------------------------------------------------------

Write-Host "`n=== AFTER ===" -ForegroundColor Cyan
$after = Get-Sgs
Write-Host "  security groups: $after"

Write-Host "`n=== Quarantine record ===" -ForegroundColor Cyan
aws dynamodb scan --table-name innovatech-soar-quarantines --region $Region `
  --query "Items[].{Instance:instance_id.S,At:quarantined_at.S,Playbook:playbook_id.S,Status:status.S}" `
  --output table

Write-Host "`n=== Verdict ===" -ForegroundColor Cyan
if ($after -eq $QuarantineSg) {
    Write-Host "  PASS - instance isolated automatically" -ForegroundColor Green
    Write-Host "  Was: $before"
    Write-Host "  Now: $after  (no ingress, no egress)"
    Write-Host "  The instance is still running; only its network reachability changed.`n"
} else {
    Write-Host "  FAIL - security groups unchanged" -ForegroundColor Red
    Write-Host "  Diagnose with:" -ForegroundColor Yellow
    Write-Host "    aws logs tail /aws/lambda/innovatech-soar-action-quarantine-host --since 5m --region $Region`n"
}
