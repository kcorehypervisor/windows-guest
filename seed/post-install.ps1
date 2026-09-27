# Runs twice from autounattend FirstLogonCommands, as Administrator.
# First pass installs NetKVM and enables SAC, then reboots if the NIC has no address yet.
# Second pass installs OpenSSH Server and shuts the guest down so the build can finish.

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\kcore' | Out-Null
Start-Transcript -Path 'C:\ProgramData\kcore\post-install.log' -Append

function Find-SeedDrive {
    foreach ($letter in [char[]](67..90)) {
        $root = "${letter}:\"
        if (Test-Path ($root + 'kcore-windows-seed.txt')) {
            return $root
        }
    }
    throw 'kcore windows seed ISO not found'
}

function Enable-Sac {
    bcdedit /emssettings emsport:1 emsbaudrate:115200
    bcdedit /ems on
    bcdedit /bootems on
}

function Install-NetKvm {
    param([string]$Seed)
    $inf = Join-Path $Seed 'NetKVM\2k22\amd64\netkvm.inf'
    if (-not (Test-Path $inf)) {
        Write-Output "NetKVM inf missing: $inf"
        return
    }
    pnputil /add-driver $inf /install
}

function Wait-Ipv4 {
    foreach ($i in 1..30) {
        $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
        if ($addrs) {
            Write-Output ("IPv4: " + ($addrs.IPAddress -join ', '))
            return $true
        }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Install-OpenSsh {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    }
    Start-Service sshd
    Set-Service -Name sshd -StartupType Automatic
    $rule = Get-NetFirewallRule -Name 'kcore-sshd' -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name 'kcore-sshd' -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    }
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\' -Name 'fDenyTSConnections' -Value 0
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4:8,any dir=in action=allow
}

$seed = Find-SeedDrive
Write-Output "seed drive $seed"
Enable-Sac
Install-NetKvm -Seed $seed

$stageFile = 'C:\ProgramData\kcore\stage.txt'
$stage = if (Test-Path $stageFile) { (Get-Content $stageFile -Raw).Trim() } else { '' }

if ($stage -ne 'rebooted') {
    if (Wait-Ipv4) {
        Install-OpenSsh
        Set-Content $stageFile 'done'
        Stop-Transcript
        shutdown /s /t 5 /f
        exit 0
    }
    Set-Content $stageFile 'rebooted'
    Stop-Transcript
    shutdown /r /t 5 /f
    exit 0
}

if (Wait-Ipv4) {
    Install-OpenSsh
    Set-Content $stageFile 'done'
} else {
    Set-Content 'C:\ProgramData\kcore\openssh-failed.txt' 'no IPv4 after reboot; SAC is enabled'
}

Stop-Transcript
shutdown /s /t 5 /f
exit 0
