# =============================================================================
# Operational recovery: release a host from quarantine.
#
# Restores the security groups recorded at quarantine time, rather than
# guessing. Deliberately manual: releasing a host that was isolated for a
# compromise indicator is a decision a human should make after investigating,
# not something the system should undo on a timer.
# =============================================================================

$ErrorActionPreference = "Stop"
$Region     = "eu-central-1"
$InstanceId = "i-049e95348a865e18d"

$record = aws dynamodb get-item --table-name innovatech-soar-quarantines --region $Region `
    --key "{\"instance_id\":{\"S\":\"$InstanceId\"}}" --output json | ConvertFrom-Json

if (-not $record.Item) {
    Write-Host "No quarantine record for $InstanceId - nothing to restore." -ForegroundColor Yellow
    exit 0
}

$original = $record.Item.original_security_groups.L | ForEach-Object { $_.S }
Write-Host "Restoring $InstanceId to: $($original -join ', ')"

aws ec2 modify-instance-attribute --instance-id $InstanceId --groups $original --region $Region

aws dynamodb update-item --table-name innovatech-soar-quarantines --region $Region `
    --key "{\"instance_id\":{\"S\":\"$InstanceId\"}}" `
    --update-expression "SET #s = :s" `
    --expression-attribute-names '{\"#s\":\"status\"}' `
    --expression-attribute-values '{\":s\":{\"S\":\"released\"}}' | Out-Null

Write-Host "Restored. Current groups:" -ForegroundColor Green
aws ec2 describe-instances --instance-ids $InstanceId --region $Region `
  --query "Reservations[0].Instances[0].SecurityGroups[].GroupId" --output text
