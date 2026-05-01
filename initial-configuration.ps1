 param(
    [Parameter(Mandatory=$true)][string]$IP_ADDRESS,
    [Parameter(Mandatory=$true)][int]$PREFIX,
    [Parameter(Mandatory=$true)][string]$GATEWAY,
    [Parameter(Mandatory=$true)][string[]]$DNS_SERVER,
    [Parameter(Mandatory=$true)][string]$USER_NAME,
    [Parameter(Mandatory=$true)][string]$SSH_PUBLIC_KEY
)

# --- Configuration Settings ---
$CUSTOM_SSH_PORT = 2222  # Change to 22 if you prefer default
# ------------------------------

# --- 0. Logging Setup ---
$logFolder = "C:\Scripts"
$logFile   = Join-Path $logFolder "customization.log"
if (-not (Test-Path $logFolder)) { New-Item -Path $logFolder -ItemType Directory -Force }
Start-Transcript -Path $logFile -Append

Write-Host "=== Starting Hardened Configuration for Win11 / Server 2025 ==="

# --- 1. Identify Deployment Drive ---
$d = (Get-Volume | Where-Object {$_.FileSystemLabel -eq 'Win11_Custom'}).DriveLetter

# --- 2. Install VirtIO Agent and Drivers ---
if ($d) {
    Write-Host "Installing VirtIO Components..."
    $virtioPath = "$($d):\deployment\virtio-win-guest-tools.exe"
    if (Test-Path $virtioPath) { Start-Process $virtioPath -ArgumentList '/install','/passive','/norestart' -Wait }
    $virtioMsi = "$($d):\deployment\virtio\virtio-win-gt-x64.msi"
    if (Test-Path $virtioMsi) { Start-Process msiexec.exe -ArgumentList "/i `"$virtioMsi`" /quiet /qn /norestart" -Wait }
}

# --- 3. Configure VirtIO Network and Static IP ---
Write-Host "Configuring Network Adapter..."
for($i=0; $i -lt 15; $i++) {
    $n = Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -match 'VirtIO' }
    if ($n) { break }
    Start-Sleep -Seconds 5
}

if ($n) {
    $name = $n[0].Name
    Set-NetConnectionProfile -InterfaceAlias $name -NetworkCategory Private -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceAlias $name -DHCP Disabled -ErrorAction SilentlyContinue
    Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
    New-NetIPAddress -InterfaceAlias $name -IPAddress $IP_ADDRESS -PrefixLength $PREFIX -DefaultGateway $GATEWAY -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceAlias $name -ServerAddresses $DNS_SERVER

    # Disable NetBIOS via CIM
    Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' | 
        Invoke-CimMethod -MethodName SetTcpipNetbios -Arguments @{TcpipNetbiosOptions = 2}
}

# --- 4. Install Software (PS7 & OpenSSH) ---
if ($d) {
    $ps7Msi    = Join-Path "$($d):\" "deployment\PowerShell-7.msi"
    $sshMsi    = Join-Path "$($d):\" "deployment\OpenSSH-Win64.msi"
    $LeoStream = Join-Path "$($d):\" "deployment\LeostreamAgentSetup.exe"
    $DcVServer = Join-Path "$($d):\" "deployment\nice-dcv-server.msi"
    $LicenseDcvSource = Join-Path "$($d):\" "deployment\license.dcv"
    $LicenseDcvTarget  = "C:\Program Files\NICE\DCV\Server\license\license.lic"
    if (Test-Path $ps7Msi) { Start-Process msiexec.exe -ArgumentList "/i `"$ps7Msi`" /quiet /qn /norestart" -Wait }
    if (Test-Path $sshMsi) { Start-Process msiexec.exe -ArgumentList "/i `"$sshMsi`" /quiet /qn /norestart" -Wait }    
    if (Test-Path $LeoStream) {Start-Process -FilePath $LeoStream -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/NORUN", "/CONNECTLOGIN", "/CBADDRESS=poseidon02.lcps.net", "/LANG=enUS", "/TASKS=singlesignon" -Wait }
    if (Test-Path $DcVServer) { Start-Process msiexec.exe -ArgumentList "/i `"$DcVServer`" /quiet /norestart" -Wait }
    if (Test-Path $LicenseDcvSource) { copy-item -Path $LicenseDcvSource -Destination $LicenseDcvTarget}
}


# --- 5. Users and Local Groups ---
Write-Host "Configuring Local Group Membership..."
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $USER_NAME -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group 'Remote Management Users' -Member $USER_NAME -ErrorAction SilentlyContinue

# --- 6. SECURE Remote Access (WinRM & SSH Hardening) ---
Write-Host "Applying Security Hardening..."

# RDP: Enable
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue

# WinRM: Hardened (Disable Basic & Unencrypted)
try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Set-WSManQuickConfig -Force -SkipNetworkProfileCheck
    Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $false -Force
    Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false -Force
} catch {
    Write-Warning "WinRM setup encountered an issue."
}

# SSH: Hardened Configuration
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType 'Automatic'

$cfg = 'C:\ProgramData\ssh\sshd_config'
if (Test-Path $cfg) {
    $content = Get-Content $cfg
    $content = $content | ForEach-Object {
        # 1. Port & Interface Hardening
        if ($_ -match '^#?Port 22') { "Port $CUSTOM_SSH_PORT" }
        elseif ($_ -match '^#?ListenAddress 0.0.0.0') { "ListenAddress $IP_ADDRESS" }
        
        # 2. Authentication Hardening
        elseif ($_ -match '^#?PubkeyAuthentication') { "PubkeyAuthentication yes" }
        elseif ($_ -match '^#?PasswordAuthentication') { "PasswordAuthentication no" }
        elseif ($_ -match '^#?PermitEmptyPasswords') { "PermitEmptyPasswords no" }
        elseif ($_ -match '^#?StrictModes') { "StrictModes yes" }
        
        # 3. Path Hardening (Ensure non-ProgramData path for user keys)
        elseif ($_ -match '^#?AuthorizedKeysFile' -and $_ -notmatch 'PROGRAMDATA') { "AuthorizedKeysFile .ssh/authorized_keys" }
        else { $_ }
    }
    
    # 4. Access Restriction
    if ($content -notmatch "AllowGroups administrators") { $content += "`nAllowGroups administrators" }

    # 5. FIX: Ensure Administrators group pulls keys from User Profile, not ProgramData
    $content = $content -replace '(?m)^Match Group administrators', '#Match Group administrators' `
                        -replace '(?m)^\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys', '#AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
    
    $content | Set-Content $cfg
}

# --- 7. Firewall & Permission Hardening ---
Write-Host "Finalizing SSH security..."

# Open Custom Firewall Port
Remove-NetFirewallRule -DisplayName "OpenSSH Server*" -ErrorAction SilentlyContinue
New-NetFirewallRule -Name "OpenSSH-Server-In-TCP-Custom" -DisplayName "OpenSSH Server (Port $CUSTOM_SSH_PORT)" `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $CUSTOM_SSH_PORT

# SSH Key & Permission Hardening
$sshFolder = "C:\Users\$USER_NAME\.ssh"
if (-not (Test-Path $sshFolder)) { New-Item -ItemType Directory -Force -Path $sshFolder }

$authKeys = Join-Path $sshFolder "authorized_keys"
$SSH_PUBLIC_KEY | Out-File -FilePath $authKeys -Encoding utf8 -Force

# Secure the folder and key file (StrictModes compliance)
icacls.exe $sshFolder /inheritance:r /grant "SYSTEM:(OI)(CI)F" /grant "${USER_NAME}:(OI)(CI)F"
icacls.exe $authKeys /inheritance:r /grant 'SYSTEM:F' /grant "${USER_NAME}:F"

Restart-Service sshd
Disable-LocalUser -Name 'Administrator' -ErrorAction SilentlyContinue

# --- 8. Registry & Intune ---
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'DontDisplayLastUserName' -Value 1
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableFirstLogonAnimation' -Value 0

#Manual registry changes so DCV Server operates as expected


$sessionPath = "Registry::HKEY_USERS\S-1-5-18\Software\GSettings\com\nicesoftware\dcv\session-management"
$securityPath = "Registry::HKEY_USERS\S-1-5-18\Software\GSettings\com\nicesoftware\dcv\security"


if (!(Test-Path $sessionPath)) { New-Item -Path $sessionPath -Force }
if (!(Test-Path $securityPath)) { New-Item -Path $securityPath -Force }


New-ItemProperty -Path $sessionPath -Name "create-session" -Value 0 -PropertyType DWord -Force -ErrorAction Ignore
New-ItemProperty -Path $securityPath -Name "auth-token-verifier" -Value "https://poseidon.xxx.xxx/rest/dcv_auth" -PropertyType String -Force -ErrorAction Ignore
New-ItemProperty -Path $securityPath -Name "no-tls-strict" -Value 1 -PropertyType DWord -Force -ErrorAction Ignore


#Apply latest windows updates
Get-WindowsUpdate -MicrosoftUpdate
Install-WindowsUpdate -AcceptAll -AutoReboot 


$ppkg = "$($d):\deployment\vdi-labs.ppkg"
if ($d -and (Test-Path $ppkg)) {
    Write-Host "Applying Provisioning Package..."
    Install-ProvisioningPackage -PackagePath $ppkg -QuietInstall -ErrorAction  Stop
}

Write-Host "=== Configuration Complete. Rebooting in 5 seconds... ==="
#Eject iso and autounattend.xml
(New-Object -ComObject Shell.Application).Namespace(17).ParseName("D:").InvokeVerb("Eject")
(New-Object -ComObject Shell.Application).Namespace(17).ParseName("E:").InvokeVerb("Eject")


#Set Powershell 7 as default shell for SSH  

# PowerShell version of your script
$pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"

if (Test-Path $pwshPath) {
    Write-Host "PowerShell 7 found. Setting as SSH default..." -ForegroundColor Cyan
    # Using the native PowerShell registry command
    $registryPath = "HKLM:\SOFTWARE\OpenSSH"
    if (-not (Test-Path $registryPath)) { New-Item -Path $registryPath -Force }
    
    Set-ItemProperty -Path $registryPath -Name "DefaultShell" -Value $pwshPath
    Write-Host "Success! New SSH sessions will use PowerShell 7." -ForegroundColor Green
} else {
    Write-Error "PowerShell 7 not found at $pwshPath"
    exit 1
}

Stop-Transcript
Restart-Computer -Force 
