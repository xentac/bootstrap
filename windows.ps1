# Make a Windows machine reachable by Ansible from nixos-config (its ADR 0012).
# Run once, in an administrator PowerShell:
#
#   irm https://raw.githubusercontent.com/xentac/bootstrap/<commit>/windows.ps1 | iex
#
# It installs the OpenSSH server, opens port 22 to the tailnet only, makes
# PowerShell the login shell, creates a hidden local administrator
# `ansible` that logs in with a key only, and turns off password logins.
# After the first Ansible run, Ansible owns these settings. Safe to run
# again: every step checks its current state first.

$ErrorActionPreference = 'Stop'

$AnsibleUser = 'ansible'
$AnsibleKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDsGpAOnEFlBGmV0OwpqfoYcb5LRzLlup0zG2ikQVHLJ ansible@nixos-config'
$TailnetRanges = '100.64.0.0/10', 'fd7a:115c:a1e0::/48'
# Well-known SIDs, so that the script also works on a non-English Windows.
$AdministratorsSid = 'S-1-5-32-544'
$SystemSid = 'S-1-5-18'

# `#Requires -RunAsAdministrator` is ignored under iex, so check by hand.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this in an administrator PowerShell.'
}

# OpenSSH server. The first start creates the host keys and sshd_config.
$capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($capability.State -ne 'Installed') {
    Write-Host 'Installing the OpenSSH server...'
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

# The capability's firewall rule allows port 22 from anywhere. Limit it to
# the tailnet, on every network profile (Windows can class the Tailscale
# adapter as Public).
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($rule) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any -RemoteAddress $TailnetRanges
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any `
        -RemoteAddress $TailnetRanges | Out-Null
}

# Ansible's Windows modules expect PowerShell, not cmd.
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -PropertyType String -Force `
    -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null

# The account. Its random password is thrown away: key logins do not use
# it, and password logins are turned off below.
if (-not (Get-LocalUser -Name $AnsibleUser -ErrorAction SilentlyContinue)) {
    $bytes = New-Object byte[] 48
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $password = ConvertTo-SecureString ([Convert]::ToBase64String($bytes)) -AsPlainText -Force
    New-LocalUser -Name $AnsibleUser -Password $password -PasswordNeverExpires -AccountNeverExpires `
        -Description 'Ansible from nixos-config. Key login only.' | Out-Null
}
try {
    Add-LocalGroupMember -SID $AdministratorsSid -Member $AnsibleUser
} catch [Microsoft.PowerShell.Commands.MemberExistsException] {
}
# Keep it off the sign-in screen.
$userList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
New-Item -Path $userList -Force | Out-Null
New-ItemProperty -Path $userList -Name $AnsibleUser -PropertyType DWord -Value 0 -Force | Out-Null

# For members of Administrators, sshd reads this file, not ~\.ssh\authorized_keys,
# and ignores it unless only Administrators and SYSTEM can read it. Any
# administrator account accepts the keys in it.
$keysFile = "$env:ProgramData\ssh\administrators_authorized_keys"
$keys = @()
if (Test-Path $keysFile) { $keys = @(Get-Content -Path $keysFile) }
if ($keys -notcontains $AnsibleKey) {
    $keys += $AnsibleKey
    # UTF-8 without a BOM: sshd does not read a BOM.
    [IO.File]::WriteAllText($keysFile, (($keys -join "`n") + "`n"))
}
icacls.exe $keysFile /inheritance:r /grant "*${AdministratorsSid}:F" /grant "*${SystemSid}:F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed on $keysFile" }

# Password logins off. Edit the existing line in place: the default file ends
# with a `Match Group administrators` block, and a line appended after it
# would only apply inside that block.
$configFile = "$env:ProgramData\ssh\sshd_config"
$config = [IO.File]::ReadAllText($configFile)
$pattern = '(?m)^#?[ \t]*PasswordAuthentication[ \t]+\S+'
if ($config -match $pattern) {
    $config = [regex]::Replace($config, $pattern, 'PasswordAuthentication no')
} else {
    $config = "PasswordAuthentication no`n" + $config
}
[IO.File]::WriteAllText($configFile, $config)
& "$env:SystemRoot\System32\OpenSSH\sshd.exe" -t
if ($LASTEXITCODE -ne 0) { throw "sshd -t rejected $configFile" }
Restart-Service -Name sshd

# The addresses that go into the nixos-config machine inventory.
Write-Host "Done. Add this machine to the inventory in nixos-config:"
Write-Host "  hostname: $env:COMPUTERNAME"
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    tailscale ip | ForEach-Object { Write-Host "  tailnet IP: $_" }
} else {
    Write-Warning 'Tailscale is not installed. Ansible connects over the tailnet, so install it next.'
}
