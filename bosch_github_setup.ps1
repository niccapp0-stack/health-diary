# One time GitHub setup for the nightly Bosch ride refresh
# Run in PowerShell:
#   powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\bosch_github_setup.ps1"
#
# What it does:
#   1. Installs Git for Windows if it is missing (a Windows permission prompt may appear).
#   2. Turns C:\Users\<you>\health-diary into a clone of github.com/niccapp0-stack/health-diary,
#      keeping the ride files already in it.
#   3. Does a test push, which opens a browser window once so you can sign in to GitHub.
#      Git remembers the sign in, so the nightly task can push on its own from then on.

$ErrorActionPreference = 'Stop'
$Repo   = 'https://github.com/niccapp0-stack/health-diary.git'
$Folder = Join-Path $env:USERPROFILE 'health-diary'
New-Item -ItemType Directory -Force -Path $Folder | Out-Null

function Say($m) { Write-Host "`n== $m" -ForegroundColor Cyan }

# ---- 1. git --------------------------------------------------------------------
$gitPaths = @("$env:ProgramFiles\Git\cmd", "${env:ProgramFiles(x86)}\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd")
$env:Path = ($gitPaths -join ';') + ';' + $env:Path
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Say 'Installing Git for Windows with winget. Accept the permission prompt if one appears.'
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    $env:Path = ($gitPaths -join ';') + ';' + $env:Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git did not install. Install it from https://git-scm.com/download/win then run this script again.'
    }
}
Say ("Using " + (git --version))
$ErrorActionPreference = 'Continue'

# ---- 2. make the folder a clone -----------------------------------------------
Set-Location $Folder
if (-not (Test-Path (Join-Path $Folder '.git'))) {
    Say 'Connecting the health-diary folder to GitHub'
    git init -q
    git remote add origin $Repo
    git fetch -q origin main
    # keep whatever ride files are already here, then lay the repo over the top
    $keep = Join-Path $env:TEMP ('bosch-keep-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $keep | Out-Null
    Get-ChildItem -Path $Folder -File | Where-Object { $_.Name -ne '.git' } | Copy-Item -Destination $keep -Force
    git reset -q --hard origin/main
    git branch -q -M main
    git branch -q --set-upstream-to=origin/main main
    Get-ChildItem -Path $keep -File | Where-Object { $_.Name -like 'bosch_*' } | Copy-Item -Destination $Folder -Force
    Remove-Item -Recurse -Force $keep
} else {
    Say 'Folder is already a git clone'
    git remote set-url origin $Repo
}
git config user.name  'Nic Capp'
git config user.email 'niccapp0-stack@users.noreply.github.com'
git config pull.rebase false
git config credential.helper manager

# ---- 3. sign in and test the push ---------------------------------------------
Say 'Testing the push. A browser window will open once for you to sign in to GitHub.'
git add bosch_dashboard.html bosch_ride_map.html
if (git status --porcelain) {
    git commit -q -m "Bosch ride refresh $(Get-Date -Format 'yyyy-MM-dd')"
}
git push origin main
if ($LASTEXITCODE -eq 0) {
    Say 'GitHub push works. The nightly refresh will now push automatically.'
} else {
    throw 'The push failed. Send the message above to Claude.'
}
