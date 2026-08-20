# =============================================================================
# Reset helper: remove every SOAR-created deny rule from the platform NACL.
#
# For repeated test runs and for clearing state before a live demonstration.
# Only touches rules in the 100-400 range, which is the band reserved for
# machine-authored policy; static baseline rules below 100 are left alone.
# =============================================================================

$Region = "eu-central-1"
$NaclId = "acl-068c30bcdb9226b04"

$entries = aws ec2 describe-network-acls --network-acl-ids $NaclId --region $Region `
  --query "NetworkAcls[0].Entries[?RuleAction=='deny' && Egress==``false`` && RuleNumber>=``100`` && RuleNumber<``400``].RuleNumber" `
  --output json | ConvertFrom-Json

if (-not $entries) { Write-Host "No SOAR deny rules present."; exit 0 }

foreach ($n in $entries) {
    Write-Host "Removing NACL rule $n"
    aws ec2 delete-network-acl-entry --network-acl-id $NaclId --rule-number $n --region $Region
}

$items = aws dynamodb scan --table-name innovatech-soar-blocks --region $Region `
  --query "Items[].cidr.S" --output json | ConvertFrom-Json
foreach ($c in $items) {
    aws dynamodb delete-item --table-name innovatech-soar-blocks --region $Region `
      --key "{\"cidr\":{\"S\":\"$c\"}}" | Out-Null
    Write-Host "Cleared block record for $c"
}
Write-Host "Reset complete." -ForegroundColor Green
