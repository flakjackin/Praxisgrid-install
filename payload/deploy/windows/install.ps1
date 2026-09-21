<#
.SYNOPSIS
    Install PraxisGrid on a Windows host, through WSL2.

.DESCRIPTION
    There is no native Windows install, and this is not a limitation being
    worked around -- it is the same install everyone else runs.

    A runner is a machine with hands: it holds every identity's vendor CLI
    logins under per-identity HOME directories, mounts the repository
    checkouts, and executes the CLIs an agent thinks with. Those guarantees
    are POSIX ones. The credential homes are 0700 and the secrets inside them
    0600; on Windows `chmod` only toggles the read-only bit, so those calls
    would succeed and protect nothing. A deploy command is killed by process
    group so a surviving `kubectl` cannot hold an open handle on the
    kubeconfig being deleted. Identity isolation is `HOME` itself.

    So the runner stays a Linux container, and this script's job is to make
    the Windows host able to run one and then hand off to the Linux installer,
    which is the same file a bare Ubuntu host runs.

    Every step here that a person could have performed by hand, it performs.
    What it still refuses are the two decisions that are not an installer's to
    make: converting an existing WSL1 distribution, which rewrites its whole
    filesystem, and running against a distribution that is not Ubuntu.

.EXAMPLE
    .\deploy\windows\install.ps1

.EXAMPLE
    .\deploy\windows\install.ps1 -Distribution Ubuntu -Yes
#>
[CmdletBinding()]
param(
    # Which WSL distribution to install into. Defaults to the WSL default, or
    # to a freshly registered Ubuntu when the machine has none.
    [string] $Distribution,
    # Answer every prompt, for an unattended install. Cannot supply the
    # administrator password -- there is no default to agree to; set
    # PRAXISGRID_ADMIN_PASSWORD for that.
    [switch] $Yes,
    # Build the images from this checkout instead of pulling released ones.
    # Only available when this is a checkout: a payload has no Dockerfiles.
    [switch] $BuildLocal,
    # Skip the port-forwarding offer at the end.
    [switch] $NoPortProxy
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string] $Text) Write-Host "    $Text" }
function Write-Warn { param([string] $Text) Write-Host "    $Text" -ForegroundColor Yellow }
function Fail {
    param([string] $Text)
    Write-Host ""
    Write-Host $Text -ForegroundColor Red
    exit 1
}

function Confirm-Step {
    param([string] $Question)
    if ($Yes) { return $true }
    if ([Console]::IsInputRedirected) {
        Fail @"
$Question
Re-run with -Yes to allow this without a prompt.
"@
    }
    $reply = Read-Host "$Question [Y/n]"
    return ($reply -eq '' -or $reply -match '^[Yy]')
}

function Invoke-Wsl {
    <# wsl.exe writes UTF-16LE. Read it as such rather than letting the
       console encoding turn every distribution name into "U.b.u.n.t.u". #>
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $previous = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        return (& wsl.exe @Arguments 2>&1) -join "`n"
    } finally {
        [Console]::OutputEncoding = $previous
    }
}

function Invoke-WslScript {
    <# A shell script reaches the distribution base64-encoded rather than as
       an argument. Anything else has to survive PowerShell's native-argument
       quoting and then the shell's, and a `sed` expression full of brackets,
       backslashes and quotes is exactly the thing that arrives subtly
       different from what was written. #>
    param([Parameter(Mandatory = $true)] [string] $Script)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    & wsl.exe -d $target.Name -u root -- sh -c "echo $encoded | base64 -d | sh -e"
    return $LASTEXITCODE
}

$isAdministrator = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Fail "This script installs PraxisGrid on a Windows host. On Linux run ./install.sh."
}

# --- Resuming after a restart -----------------------------------------------
#
# Enabling the WSL feature needs a restart, and that restart is the one thing
# no design removes. What it does remove is the operator having to know to
# come back: a RunOnce entry re-runs the entry point in a console at the next
# sign-in. HKCU rather than HKLM so it runs as the person who started this,
# who can then accept the elevation prompt.

$ResumeKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$ResumeName = 'PraxisGridInstall'

function Register-Resume {
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    if ($env:PRAXISGRID_BOOTSTRAP_URL) {
        $command = "irm $($env:PRAXISGRID_BOOTSTRAP_URL) | iex"
    } else {
        $command = "& '$PSCommandPath'"
    }
    try {
        New-ItemProperty -Path $ResumeKey -Name $ResumeName -PropertyType String -Force `
            -Value "$shell -NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$command`"" | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Request-Restart {
    param([string] $Because)
    Write-Host ""
    Write-Step "A restart is needed"
    Write-Note $Because
    if (Register-Resume) {
        Write-Note "PraxisGrid will pick up where it left off when you sign back in."
    } else {
        Write-Warn "Could not register the automatic resume. After restarting, run this again."
    }
    Write-Host ""
    if (Confirm-Step "Restart Windows now?") {
        Restart-Computer -Force
        exit 0
    }
    Write-Note "Restart when convenient. Nothing else is needed from you first."
    exit 0
}

# --- WSL itself -------------------------------------------------------------
#
# `wsl.exe` exists on every supported Windows build even with no distribution
# installed, so its presence proves nothing on its own -- the questions are
# whether the feature is enabled, whether a distribution exists, and whether
# it is version 2. Version 1 has no real kernel: no cgroups, no Docker, and
# the filesystem behaves like the Windows one this install specifically has to
# stay off.

Write-Step "Checking WSL"

$build = [int] (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
if ($build -lt 19041) {
    Fail @"
This machine is Windows build $build, and WSL2 needs build 19041 (Windows 10
version 2004) or later. Any Windows 11 is new enough.

Windows Update is the whole remedy, and there is no PraxisGrid install on this
machine until it has run.
"@
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    if (-not $isAdministrator) {
        Fail @"
WSL is not installed, and installing it needs an administrator.

Open PowerShell as administrator and run this again.
"@
    }
    # `wsl.exe` lives in System32 on every build this script accepts, so its
    # absence means the optional features have never been enabled -- and
    # `wsl --install`, which would enable them, is the very command that is
    # missing. DISM is what enables a Windows feature without it. Both
    # features are needed: the subsystem, and the virtual machine platform
    # WSL2 runs its kernel on.
    Write-Note "WSL is not installed. Enabling the Windows features it needs."
    if (-not (Confirm-Step "Enable WSL2 on this machine?")) { exit 1 }
    foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        & dism.exe /online /enable-feature /featurename:$feature /all /norestart | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
            Fail "Could not enable the Windows feature '$feature' (dism exit $LASTEXITCODE)."
        }
    }
    Request-Restart "Windows needs to restart to finish enabling WSL2."
}

$listing = Invoke-Wsl --list --verbose
$distributions = @()
foreach ($line in ($listing -split "`r?`n")) {
    $text = $line -replace "`0", ''
    if ($text -match '^\s*(\*?)\s*(\S+)\s+(\S+)\s+(\d+)\s*$') {
        if ($Matches[2] -eq 'NAME') { continue }
        $distributions += [pscustomobject]@{
            Name    = $Matches[2]
            State   = $Matches[3]
            Version = [int] $Matches[4]
            Default = ($Matches[1] -eq '*')
        }
    }
}

if (-not $distributions) {
    if (-not $isAdministrator) {
        Fail @"
WSL is present but has no installed distribution, and registering one needs an
administrator.

Open PowerShell as administrator and run this again.
"@
    }
    Write-Note "WSL has no distribution installed."
    if (-not (Confirm-Step "Install Ubuntu into WSL2 now?")) { exit 1 }
    # --no-launch registers the distribution without the first-run account
    # wizard. Nothing here needs that account: the installer runs as root,
    # which is what it already required. The wizard was a stop with nothing
    # on the other side of it.
    & wsl.exe --set-default-version 2 | Out-Null
    & wsl.exe --install --no-launch -d Ubuntu
    if ($LASTEXITCODE -ne 0) {
        Request-Restart "Enabling the WSL2 platform needs a restart before Ubuntu can be registered."
    }
    $listing = Invoke-Wsl --list --verbose
    $distributions = @()
    foreach ($line in ($listing -split "`r?`n")) {
        $text = $line -replace "`0", ''
        if ($text -match '^\s*(\*?)\s*(\S+)\s+(\S+)\s+(\d+)\s*$') {
            if ($Matches[2] -eq 'NAME') { continue }
            $distributions += [pscustomobject]@{
                Name = $Matches[2]; State = $Matches[3]
                Version = [int] $Matches[4]; Default = ($Matches[1] -eq '*')
            }
        }
    }
    if (-not $distributions) {
        Request-Restart "Ubuntu was registered but WSL is not serving it yet."
    }
}

if ($Distribution) {
    $target = $distributions | Where-Object { $_.Name -eq $Distribution } | Select-Object -First 1
    if (-not $target) {
        $names = ($distributions | ForEach-Object { $_.Name }) -join ', '
        Fail "No WSL distribution named '$Distribution'. Installed: $names"
    }
} else {
    # An Ubuntu one is preferred over the default, because the default may be
    # a docker-desktop helper distribution or something the operator uses for
    # unrelated work, and the Linux installer supports Ubuntu.
    $target = $distributions | Where-Object { $_.Name -match '^Ubuntu' -and $_.Version -eq 2 } | Select-Object -First 1
    if (-not $target) { $target = $distributions | Where-Object { $_.Default } | Select-Object -First 1 }
    if (-not $target) { $target = $distributions | Select-Object -First 1 }
}

if ($target.Version -ne 2) {
    Fail @"
'$($target.Name)' is running on WSL version $($target.Version). PraxisGrid needs WSL2.

Version 1 has no Linux kernel, so it cannot run Docker, and its filesystem is
the Windows one -- which is the filesystem this install has to stay off.

Converting it rewrites the distribution's entire filesystem and takes an
unpredictable amount of time, so this installer will not do it to a
distribution you already use. Run it yourself, or install a second Ubuntu:

  wsl --set-version $($target.Name) 2
  wsl --set-default-version 2

  # or, to leave that one alone:
  wsl --install -d Ubuntu
  .\install.ps1 -Distribution Ubuntu
"@
}
Write-Note "Using WSL2 distribution '$($target.Name)'."

if ($target.State -ne 'Running') {
    & wsl.exe -d $target.Name -u root -- true 2>&1 | Out-Null
}

# --- Ubuntu inside it -------------------------------------------------------
#
# The Linux installer refuses anything that is not Ubuntu, and it is better to
# say so here than to hand off and have it exit from inside another shell.

$osRelease = (& wsl.exe -d $target.Name -u root -- sh -c "cat /etc/os-release 2>/dev/null") -join "`n"
if ($osRelease -notmatch '(?m)^ID=ubuntu') {
    $id = if ($osRelease -match '(?m)^ID=(.+)$') { $Matches[1].Trim() } else { 'unknown' }
    Fail @"
'$($target.Name)' is $id, and the Linux installer supports Ubuntu.

Install Ubuntu alongside it and point this script at that one:
  wsl --install -d Ubuntu
  .\install.ps1 -Distribution Ubuntu
"@
}

# --- Docker -----------------------------------------------------------------
#
# Two supported shapes, and the difference matters because installing the
# second on top of the first leaves the host with two daemons. Docker Desktop
# puts a working `docker` on PATH inside every integrated distribution while
# none of them runs a daemon; Docker Engine installed into the distribution
# runs its own, and needs systemd enabled to come back after a reboot.
#
# Docker Desktop is used when it is already there and integrated. It is no
# longer a prerequisite: an operator who has not installed it gets Docker
# Engine inside the distribution, which the Linux installer already knows how
# to obtain from Docker's own apt repository. What this section does is make
# that route work unattended, by enabling systemd first -- without it the
# daemon has no way to be started at boot, and `systemctl enable --now docker`
# fails on a missing bus.

Write-Step "Checking Docker inside '$($target.Name)'"

function Test-DockerDaemon {
    & wsl.exe -d $target.Name -u root -- sh -c "docker info >/dev/null 2>&1" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

if (Test-DockerDaemon) {
    Write-Note "A Docker daemon is already reachable."
} else {
    $desktop = Get-Command 'docker' -ErrorAction SilentlyContinue
    if ($desktop) {
        Write-Warn "Docker Desktop is installed on Windows but is not reachable from"
        Write-Warn "'$($target.Name)'. Settings -> Resources -> WSL integration, enable"
        Write-Warn "'$($target.Name)', apply, and run this again -- that is the least work."
        Write-Host ""
        Write-Note "Otherwise Docker Engine can be installed inside the distribution."
        if (-not (Confirm-Step "Install Docker Engine inside '$($target.Name)' instead?")) { exit 1 }
    } else {
        Write-Note "No Docker daemon here, and no Docker Desktop on Windows."
        Write-Note "Docker Engine will be installed inside the distribution, from"
        Write-Note "Docker's own apt repository. Docker Desktop is not needed."
        if (-not (Confirm-Step "Install Docker Engine inside '$($target.Name)'?")) { exit 1 }
    }

    # systemd first, and before the daemon exists rather than after. A
    # distribution without it has no PID 1 that can hold a service, so an
    # installed Docker would have to be started by hand at every sign-in.
    $wslConf = (& wsl.exe -d $target.Name -u root -- sh -c "cat /etc/wsl.conf 2>/dev/null") -join "`n"
    if ($wslConf -notmatch '(?m)^\s*systemd\s*=\s*true') {
        Write-Step "Enabling systemd in '$($target.Name)'"
        Invoke-WslScript @'
set -e
touch /etc/wsl.conf
# An existing systemd= line is removed rather than left above the one being
# added: a file carrying systemd=false would otherwise hold both, and which
# of the two wins is a property of WSL's parser rather than something to
# guess at.
sed -i '/^[[:space:]]*systemd[[:space:]]*=/d' /etc/wsl.conf
if grep -q '^\[boot\]' /etc/wsl.conf; then
  sed -i '0,/^\[boot\]/s//[boot]\nsystemd=true/' /etc/wsl.conf
else
  printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf
fi
'@
        if ($LASTEXITCODE -ne 0) { Fail "Could not enable systemd in '$($target.Name)'." }
        Write-Note "Restarting the distribution so it takes effect."
        & wsl.exe --terminate $target.Name | Out-Null
        & wsl.exe -d $target.Name -u root -- true 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    }
    # Docker itself is installed by the Linux installer below, which owns
    # that apt reasoning and is the same file a bare Ubuntu host runs.
    $env:PRAXISGRID_YES = '1'
}

# --- Where this install runs from -------------------------------------------
#
# The installer has to run from inside the distribution. A checkout on a
# Windows drive is translated with `wslpath` and run in place, because
# -BuildLocal needs its Dockerfiles and its build context. A payload -- the
# published installer, which has no Dockerfiles -- is copied onto the Linux
# filesystem instead, so that reruns, restarts and the `docker compose`
# commands the installer prints all name a path that keeps working.

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$isCheckout = Test-Path (Join-Path $sourceRoot 'Dockerfile')
Write-Step "Locating the installer"

function ConvertTo-WslPath {
    param([string] $WindowsPath)
    if ($WindowsPath -match '^\\\\wsl(\$|\.localhost)\\([^\\]+)\\(.*)$') {
        if ($Matches[2] -ne $target.Name) {
            Fail @"
This installer lives inside WSL distribution '$($Matches[2])', but the install
target is '$($target.Name)'. Run with -Distribution $($Matches[2]), or put it
inside '$($target.Name)'.
"@
        }
        return '/' + ($Matches[3] -replace '\\', '/')
    }
    $translated = ((& wsl.exe -d $target.Name -u root -- wslpath -a ($WindowsPath -replace '\\', '/')) -join '').Trim()
    if (-not $translated) { Fail "Could not translate '$WindowsPath' into a path inside WSL." }
    return $translated
}

$sourceInWsl = ConvertTo-WslPath $sourceRoot

if ($isCheckout) {
    $linuxPath = $sourceInWsl
    if ($linuxPath -like '/mnt/*') {
        # Not refused. Only the data root has to be on ext4 -- see the refusal
        # in deploy/ubuntu/install.sh -- and the data root defaults to
        # /var/lib/praxisgrid regardless of where the checkout sits. What a
        # checkout on /mnt costs is speed, and only when building images.
        Write-Warn "The checkout is on a Windows drive ($sourceRoot)."
        Write-Warn "That works. It is slow to build from, so if you use -BuildLocal,"
        Write-Warn "consider cloning inside the distribution instead."
    }
} else {
    if ($BuildLocal) {
        Fail @"
-BuildLocal builds the images from a checkout, and this is the published
installer, which carries no Dockerfiles.

Clone the repository and run its own entry point instead:
  git clone https://github.com/flakjackin/PraxisGrid.git
  cd PraxisGrid
  .\deploy\windows\install.ps1 -BuildLocal
"@
    }
    $linuxPath = '/opt/praxisgrid/install'
    Write-Note "Copying the installer onto the Linux filesystem."
    & wsl.exe -d $target.Name -u root -- sh -c "rm -rf '$linuxPath' && mkdir -p '$linuxPath' && cp -R '$sourceInWsl/.' '$linuxPath/' && chmod +x '$linuxPath/install.sh' '$linuxPath'/deploy/*/install.sh"
    if ($LASTEXITCODE -ne 0) { Fail "Could not copy the installer into '$($target.Name)'." }
}
Write-Note $linuxPath

# --- Hand off ---------------------------------------------------------------
#
# Every PRAXISGRID_* variable set in this PowerShell session is forwarded, so
# an unattended install is configured the same way on both operating systems.
# WSLENV is how a Windows environment variable reaches the Linux side at all;
# without naming each one there, none of them cross.

Write-Step "Running the Linux installer in '$($target.Name)'"
if ($Yes)        { $env:PRAXISGRID_YES = '1' }
if ($BuildLocal) { $env:PRAXISGRID_BUILD_LOCAL = '1' }

$forwarded = @(Get-ChildItem Env: | Where-Object { $_.Name -like 'PRAXISGRID_*' } |
                ForEach-Object { $_.Name })
if ($forwarded) {
    $existing = $env:WSLENV
    $env:WSLENV = @(($forwarded -join ':'), $existing | Where-Object { $_ }) -join ':'
    Write-Note "Forwarding: $($forwarded -join ', ')"
}

# `-u root` rather than `sudo`: a distribution registered with --no-launch has
# no user account at all, and the installer refuses to run as anyone else
# anyway. stdin is left attached so its administrator-password prompt works,
# which is also why the password is never passed as an argument.
# Invoked through `bash` and an explicit `cd` rather than `--cd` and the
# script's own shebang: `--cd` needs a recent WSL build, and a checkout on a
# Windows drive does not reliably carry an executable bit. Neither is worth
# an install failing over.
$quoted = "'" + ($linuxPath -replace "'", "'\''") + "'"
& wsl.exe -d $target.Name -u root -- bash -c "cd $quoted && bash ./deploy/ubuntu/install.sh"
$installerExit = $LASTEXITCODE
if ($installerExit -ne 0) {
    Fail "The Linux installer exited with code $installerExit. Nothing above this line was undone."
}

# --- After ------------------------------------------------------------------

$port = if ($env:PRAXISGRID_PORT) { $env:PRAXISGRID_PORT } else { '8080' }
Remove-ItemProperty -Path $ResumeKey -Name $ResumeName -ErrorAction SilentlyContinue

Write-Host ""
Write-Step "PraxisGrid is running"
Write-Note "http://localhost:$port"
Write-Host ""
Write-Note "WSL2 forwards localhost from Windows, so that address works in a"
Write-Note "Windows browser with nothing else configured. It is only reachable"
Write-Note "from this computer."

if (-not $NoPortProxy) {
    Write-Host ""
    # Performed rather than printed: this script is already elevated in the
    # ordinary case, and telling somebody to open a second administrator
    # PowerShell and paste two commands is the kind of step that makes an
    # install feel like a procedure.
    if ($isAdministrator) {
        if (Confirm-Step "Also reach PraxisGrid from other machines on this network?") {
            & netsh.exe interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 `
                connectport=$port connectaddress=127.0.0.1 | Out-Null
            if (-not (Get-NetFirewallRule -DisplayName 'PraxisGrid' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName 'PraxisGrid' -Direction Inbound `
                    -LocalPort $port -Protocol TCP -Action Allow | Out-Null
            }
            $address = (Get-NetIPAddress -AddressFamily IPv4 |
                        Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
                        Select-Object -First 1).IPAddress
            Write-Note "Forwarded. From the network: http://$address`:$port"
            Write-Note "Windows 11 22H2 and later can instead set networkingMode=mirrored"
            Write-Note "under [wsl2] in %USERPROFILE%\.wslconfig and drop the rule."
        }
    } else {
        Write-Note "To reach it from other machines, run this script as administrator,"
        Write-Note "or set networkingMode=mirrored under [wsl2] in %USERPROFILE%\.wslconfig."
    }
}

if (-not $Yes -and -not [Console]::IsInputRedirected) {
    Start-Process "http://localhost:$port"
}
