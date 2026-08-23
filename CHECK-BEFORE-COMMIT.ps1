# Run from the repository root after replacing any file, before committing.
# Every check corresponds to something that was silently reverted at least once
# during this project by an overwrite.

$script:fail = 0

function Check {
    param([string]$Name, [bool]$Ok, [string]$Fix)
    if ($Ok) {
        Write-Host "  OK      $Name" -ForegroundColor Green
    } else {
        Write-Host "  BROKEN  $Name" -ForegroundColor Red
        Write-Host "          $Fix" -ForegroundColor Yellow
        $script:fail = 1
    }
}

Write-Host "`n=== Local customisations ===" -ForegroundColor Cyan

# Select-String -Quiet returns one boolean per file when given a collection,
# so results are counted rather than tested for truthiness. The first version
# of this script got that wrong and reported a false failure.
$badPath = @(Select-String -Path ".github\workflows\*.yml" -Pattern "Program Files" -SimpleMatch)
Check "Git Bash path in all workflows" ($badPath.Count -eq 0) `
      "replace C:\Program Files\Git with C:\Git in: $($badPath.Path -join ', ')"

Check "02 triggers on its own file" `
      ((Get-Content .github\workflows\02-infrastructure.yml -Raw) -match "02-infrastructure\.yml'\]") `
      "add '.github/workflows/02-infrastructure.yml' to the push paths filter"

$badToken = @(Select-String -Path "observability\values\*.yaml" -Pattern "__LIKE_THIS__" -SimpleMatch)
Check "no placeholder-shaped text in comments" ($badToken.Count -eq 0) `
      "the validate job rejects any __TOKEN__ it cannot substitute, including in comments"

Check "IP auto-detect present" (Test-Path terraform\00-myip.tf) `
      "00-myip.tf is missing, admin_ip_cidr will prompt"

Check "admin_ip_cidr is optional" `
      ((Get-Content terraform\variables.tf -Raw) -match 'admin_ip_cidr[\s\S]{0,200}default\s*=\s*null') `
      "set default = null on admin_ip_cidr"

Check "hybrid gateway uses the local, not the var" `
      ((Get-Content terraform\21-hybrid-gateway.tf -Raw) -match 'local\.admin_ip_cidr') `
      "change cidr_blocks to [local.admin_ip_cidr]"

Check "backend config present" (Test-Path terraform\backend.tf) `
      "regenerate: terraform -chdir=terraform/bootstrap output -raw backend_config"

Check "superseded script removed" (-not (Test-Path observability\deploy-observability.sh)) `
      "delete it, the Observability pipeline replaced it"

Write-Host "`n=== Formatting and syntax ===" -ForegroundColor Cyan

terraform -chdir=terraform fmt -check -recursive | Out-Null
Check "terraform formatting" ($LASTEXITCODE -eq 0) `
      "run: terraform -chdir=terraform fmt -recursive"

if (Get-Command py -ErrorAction SilentlyContinue) {
    Push-Location soar\tests
    py -m unittest discover -s . -p "test_*.py" 2>&1 | Out-Null
    $testsOk = ($LASTEXITCODE -eq 0)
    Pop-Location
    Check "unit tests pass" $testsOk "run them locally to see the failure"
} else {
    Write-Host "  SKIP    unit tests, no python launcher on PATH" -ForegroundColor DarkGray
}

Write-Host "`n=== Secrets not staged ===" -ForegroundColor Cyan

$bad = @(git status --short | Select-String -Pattern 'terraform\.tfvars$|\.pem$|tfstate')
Check "no secrets in the working tree" ($bad.Count -eq 0) `
      "unstage them, they are gitignored for a reason"

if ($script:fail -eq 0) {
    Write-Host "`nAll checks passed, safe to commit.`n" -ForegroundColor Green
} else {
    Write-Host "`nFix the above before committing.`n" -ForegroundColor Red
    exit 1
}
