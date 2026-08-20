$ErrorActionPreference = "Continue"

Write-Host "=== IDENTITY ==="
& cmd /c "aws sts get-caller-identity 2>&1"
Write-Host "Region: $env:AWS_DEFAULT_REGION"

Write-Host "`n=== REGIONS ALLOWED ==="
& cmd /c "aws ec2 describe-regions --query ""Regions[].RegionName"" --output text 2>&1"

Write-Host "`n=== EXISTING ROLES ==="
& cmd /c "aws iam list-roles --query ""Roles[].RoleName"" --output text 2>&1"

Write-Host "`n=== INSTANCE PROFILES ==="
& cmd /c "aws iam list-instance-profiles --query ""InstanceProfiles[].InstanceProfileName"" --output text 2>&1"

Write-Host "`n=== CAN I CREATE A ROLE? ==="
'{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' |
  Out-File -Encoding ascii -NoNewline "$env:TEMP\trust.json"
& cmd /c "aws iam create-role --role-name probe-delete-me --assume-role-policy-document file://$env:TEMP/trust.json 2>&1"
& cmd /c "aws iam delete-role --role-name probe-delete-me 2>&1"
Remove-Item "$env:TEMP\trust.json" -ErrorAction SilentlyContinue

Write-Host "`n=== SERVICE ACCESS ==="
$checks = @(
  "ec2 describe-vpcs", "ec2 describe-transit-gateways", "ec2 describe-vpn-gateways",
  "ec2 describe-client-vpn-endpoints", "ec2 describe-vpc-endpoints", "ec2 describe-nat-gateways",
  "ec2 describe-network-acls", "eks list-clusters", "ecs list-clusters", "ecr describe-repositories",
  "lambda list-functions", "rds describe-db-instances", "apigateway get-rest-apis",
  "events list-rules", "sns list-topics", "sqs list-queues", "dynamodb list-tables",
  "route53 list-hosted-zones", "route53resolver list-resolver-endpoints",
  "states list-state-machines", "secretsmanager list-secrets", "ssm describe-instance-information",
  "logs describe-log-groups", "cloudwatch describe-alarms", "amp list-workspaces",
  "s3api list-buckets", "kms list-keys"
)
foreach ($c in $checks) {
  $out = (& cmd /c "aws $c 2>&1") -join " "
  if     ($LASTEXITCODE -eq 0)                                     { $s = "OK" }
  elseif ($out -match "AccessDenied|not authorized|Unauthorized")  { $s = "DENIED" }
  elseif ($out -match "explicit deny|SCP")                         { $s = "SCP-DENIED" }
  elseif ($out -match "OptInRequired|SubscriptionRequired")        { $s = "NOT-ENABLED" }
  elseif ($out -match "InvalidClientTokenId|ExpiredToken")         { $s = "BAD-CREDS" }
  else { $s = "ERR: " + $out.Substring(0, [Math]::Min(90, $out.Length)) }
  Write-Host ("{0,-42} {1}" -f $c, $s)
}

Write-Host "`n=== EC2 QUOTA (standard on-demand vCPUs) ==="
& cmd /c "aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query ""Quota.Value"" --output text 2>&1"