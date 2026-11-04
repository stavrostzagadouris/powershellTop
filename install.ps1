<#
.SYNOPSIS
    Installs the ptop alias into the current user's PowerShell $PROFILE.
#>

$ScriptPath = Join-Path $PSScriptRoot "ptop.ps1"
if (-not (Test-Path $ScriptPath)) {
    Write-Error "Could not find ptop.ps1 in $PSScriptRoot"
    exit 1
}

$ProfileDir = Split-Path -Parent $PROFILE
if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}

if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$AliasLine = "Set-Alias -Name ptop -Value `"$ScriptPath`""
$CurrentContent = Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue

if ($CurrentContent -notmatch 'Set-Alias\s+-Name\s+ptop\b') {
    Add-Content -Path $PROFILE -Value "`n$AliasLine"
    Write-Host "✔ Added 'ptop' alias to $PROFILE" -ForegroundColor Green
} else {
    Write-Host "ℹ 'ptop' alias already exists in $PROFILE" -ForegroundColor Cyan
}

Set-Alias -Name ptop -Value $ScriptPath -Scope Global
Write-Host "✔ Ready! Type 'ptop' to launch PowerShell Top." -ForegroundColor Green
