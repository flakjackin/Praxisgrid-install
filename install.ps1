<#
.SYNOPSIS
    One command, on Windows:

      irm https://raw.githubusercontent.com/flakjackin/praxisgrid-install/main/install.ps1 | iex

.DESCRIPTION
    A bootstrap fetches and dispatches. It never provisions. WSL2, the Ubuntu
    distribution, Docker, the secrets and the containers are all obtained by
    deploy/windows/install.ps1 in the payload, which is where the reasoning
    about this platform lives and where the tests point.

    Two things happen here and nowhere else, because neither is possible once
    the install is already running: elevating, since `wsl --install` needs an
    administrator and there is no way to acquire one midway; and obtaining the
    payload, since the machine may have no WSL to obtain it from.

    The payload is public and carries no secret. The only credential this path
    ever asks for is a GitHub token with `read:packages`, for the private
    images, and the Linux installer asks for that itself at the moment it
    pulls.

.EXAMPLE
    irm https://raw.githubusercontent.com/flakjackin/praxisgrid-install/main/install.ps1 | iex

.EXAMPLE
    # With options, which a piped script cannot be given:
    irm https://raw.githubusercontent.com/flakjackin/praxisgrid-install/main/install.ps1 -OutFile install.ps1
    .\install.ps1 -Distribution Ubuntu-24.04 -NoPortProxy
#>
[CmdletBinding()]
param(
    # Which WSL distribution to install into. Defaults to the WSL default, or
    # to a freshly registered Ubuntu when there is none.
    [string] $Distribution,
    # Answer every prompt. Cannot supply the administrator password -- there
    # is no default to agree to; set PRAXISGRID_ADMIN_PASSWORD for that.
    [switch] $Yes,
    # Skip the offer to forward the port to the rest of the network.
    [switch] $NoPortProxy,
    # Use an existing payload (or a checkout) instead of downloading one.
    # This is how the whole path is tested without publishing anything.
    [string] $PayloadDir = $env:PRAXISGRID_PAYLOAD_DIR
)

$ErrorActionPreference = 'Stop'

$InstallerRepo = if ($env:PRAXISGRID_INSTALLER_REPO) { $env:PRAXISGRID_INSTALLER_REPO } else { 'flakjackin/praxisgrid-install' }
$InstallerRef  = if ($env:PRAXISGRID_INSTALLER_REF)  { $env:PRAXISGRID_INSTALLER_REF }  else { 'main' }
$BootstrapUrl  = "https://raw.githubusercontent.com/$InstallerRepo/$InstallerRef/install.ps1"
# Overridable as a whole, not only by repository and ref: a deployment that
# mirrors the installer internally, or installs from a copy on a machine with
# no route to github.com, is naming an archive rather than a GitHub project.
$ArchiveUrl    = if ($env:PRAXISGRID_INSTALLER_ARCHIVE) { $env:PRAXISGRID_INSTALLER_ARCHIVE }
                 else { "https://codeload.github.com/$InstallerRepo/zip/refs/heads/$InstallerRef" }

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Fail {
    param([string] $Text)
    Write-Host ""
    Write-Host $Text -ForegroundColor Red
    exit 1
}

if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Fail @"
This bootstrap installs PraxisGrid on Windows. On Ubuntu or macOS:
  curl -fsSL https://raw.githubusercontent.com/$InstallerRepo/$InstallerRef/install.sh | bash
"@
}

# --- Elevation ---------------------------------------------------------------
#
# `wsl --install` enables Windows features and needs an administrator, and the
# port forwarding offered at the end needs one too. Acquiring it midway is not
# possible, so it is acquired before anything has been done -- a failed
# elevation then leaves a machine nothing has touched.
#
# The relaunch re-runs this same one-liner rather than carrying state across,
# because the URL is the whole state. PRAXISGRID_* variables are deliberately
# NOT forwarded on the command line: PRAXISGRID_ADMIN_PASSWORD is one of them,
# and a command line is visible in the process list. An unattended install
# starts from an administrator PowerShell, where the variables are already in
# the environment this script inherits.

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $secrets = @(Get-ChildItem Env: -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like 'PRAXISGRID_*' } | ForEach-Object { $_.Name })
    if ($secrets) {
        Fail @"
This install needs administrator rights, and relaunching would lose the
PRAXISGRID_* variables set here ($($secrets -join ', ')). A command line is
visible in the process list, so they are not forwarded through one.

Open PowerShell as administrator, set them there, and run this again.
"@
    }
    Write-Step "Elevating"
    Write-Host "    Installing WSL needs an administrator. Accept the prompt."
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $command = "irm $BootstrapUrl | iex"
    try {
        Start-Process -FilePath $shell -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', $command)
    } catch {
        Fail @"
Elevation was declined, so nothing was installed.

Open PowerShell as administrator and run:
  irm $BootstrapUrl | iex
"@
    }
    Write-Host "    Continuing in the administrator window."
    exit 0
}

# --- The payload -------------------------------------------------------------
#
# Under ProgramData rather than a temp directory: the Windows installer is
# re-run after a restart when WSL had to be enabled, and it is what an
# operator runs again to repair or upgrade an installation.

$Root = Join-Path $env:ProgramData 'PraxisGrid'

if ($PayloadDir) {
    $payload = (Resolve-Path $PayloadDir).Path
    if (-not (Test-Path (Join-Path $payload 'deploy\windows\install.ps1'))) {
        Fail "No deploy\windows\install.ps1 under the payload at $payload."
    }
    Write-Step "Using the payload at $payload"
} else {
    Write-Step "Downloading the PraxisGrid installer"
    Write-Host "    $InstallerRepo ($InstallerRef)"
    $staging = Join-Path ([IO.Path]::GetTempPath()) ("praxisgrid-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $archive = Join-Path $staging 'installer.zip'
    try {
        # Explicit TLS 1.2 for Windows PowerShell 5.1, whose default still
        # negotiates SSL3/TLS1.0 -- which github.com refuses outright, and the
        # failure reads as a broken connection rather than a protocol.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $progress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # a progress bar makes IWR ~10x slower
        try { Invoke-WebRequest -Uri $ArchiveUrl -OutFile $archive -UseBasicParsing }
        finally { $ProgressPreference = $progress }
        Expand-Archive -Path $archive -DestinationPath $staging -Force
    } catch {
        Fail @"
Could not download the installer from:
  $ArchiveUrl

$($_.Exception.Message)

Check this machine's network access to github.com.
"@
    }
    $extracted = Get-ChildItem -Path $staging -Directory -Recurse -Depth 1 |
                 Where-Object { $_.Name -eq 'payload' } | Select-Object -First 1
    if (-not $extracted) { Fail "The downloaded installer has no payload directory." }

    $payload = Join-Path $Root 'install'
    Write-Step "Installing it to $payload"
    if (Test-Path $payload) { Remove-Item -Path $payload -Recurse -Force }
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    Copy-Item -Path (Join-Path $extracted.FullName '*') -Destination $payload -Recurse -Force
    Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Hand off ----------------------------------------------------------------

$forward = @{}
if ($Distribution) { $forward['Distribution'] = $Distribution }
if ($Yes)          { $forward['Yes']          = $true }
if ($NoPortProxy)  { $forward['NoPortProxy']  = $true }
# The resumed-after-restart run needs to find this script again, and it is now
# a file rather than a pipe.
$env:PRAXISGRID_BOOTSTRAP_URL = $BootstrapUrl

& (Join-Path $payload 'deploy\windows\install.ps1') @forward
exit $LASTEXITCODE
