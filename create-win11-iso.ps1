 <#
# ==============================================================================
# WINDOWS 11 25H2 ZERO-TOUCH CUSTOMIZER (PRODUCTION READY - V3)
# ==============================================================================
<#
.SYNOPSIS
    Windows 11 Zero-Touch ISO Manager for OpenShift - MEDUSA.
.DESCRIPTION
    A modular script to either query Windows ISO indexes or process them into 
    custom, driver-injected, no-prompt ISOs for automated VM deployments of Windows 11 in OpenShift.
#>


param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("Query", "Process")]
    [string]$Action,

    [Parameter(Mandatory=$true)]
    [string]$IsoInputFolder,

    [Parameter(Mandatory=$false)]
    [int]$TargetIndex = 3,

    [Parameter(Mandatory=$false)]
    [string]$BaseDir = "C:\iso-processing",

    [Parameter(Mandatory=$false)]
    [string]$ISOName 

)

# --- 1. FUNCTION DEFINITIONS ---

function Get-WimImageInfo {
    param ([string]$IsoPath)
    Write-Host "`n--- Phase: Inspecting ISO Image Indexes ---" -ForegroundColor Cyan
    $MountDisc = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $DriveLetter = ($MountDisc | Get-Volume).DriveLetter
    $WimPath = Join-Path "$($DriveLetter):" "sources\install.wim"
    if (!(Test-Path $WimPath)) { $WimPath = Join-Path "$($DriveLetter):" "sources\install.esd" }

    if (Test-Path $WimPath) {
        $Images = Get-WindowsImage -ImagePath $WimPath
        Write-Host "Available Editions in: $(Split-Path $IsoPath -Leaf)" -ForegroundColor Yellow
        $Images | Select-Object ImageIndex, ImageName, ImageDescription, @{Name="SizeGB"; Expression={[math]::Round($_.Size / 1GB, 2)}} | Format-Table -AutoSize
    }
    Dismount-DiskImage -ImagePath $IsoPath    
}

function Expand-WindowsIso {
    param ([string]$IsoPath, [string]$ExtractPath)
    Write-Host "--- Phase: Extracting ISO ---" -ForegroundColor Cyan
    Get-WindowsImage -Mounted | Where-Object { $_.Path -like "*IsoBuilding*" } | Dismount-WindowsImage -Discard
    
    $MountDisc = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $DriveLetter = ($MountDisc | Get-Volume).DriveLetter
    
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $ExtractPath -ItemType Directory -Force | Out-Null
    
    robocopy "$($DriveLetter):\" "$ExtractPath" /E /MT:32 /R:1 /W:1 | Out-Null
    Dismount-DiskImage -ImagePath $IsoPath
    Get-ChildItem -Path $ExtractPath -Recurse | ForEach-Object { $_.Attributes = 'Archive' }
}

function Invoke-WimPatching {
    param ([string]$ExtractPath, [string]$WorkDir, [int]$TargetIndex, [string]$DriverSource, [string]$ModuleSource)
    Write-Host "--- Phase: Patching WIM (Drivers/Modules) ---" -ForegroundColor Cyan
    $WimFile = "$ExtractPath\sources\install.wim"
    $BootWim = "$ExtractPath\sources\boot.wim"
    $MountPath = Join-Path $WorkDir "Mount"
    if (!(Test-Path $MountPath)) { New-Item $MountPath -ItemType Directory -Force }

    $TempWim = "$WorkDir\temp.wim"
    Dism /Export-Image /SourceImageFile:$WimFile /SourceIndex:$TargetIndex /DestinationImageFile:$TempWim
    Move-Item $TempWim $WimFile -Force

    Dism /Mount-Image /ImageFile:$BootWim /Index:2 /MountDir:$MountPath
    Dism /Image:$MountPath /Add-Driver /Driver:$DriverSource /Recurse /ForceUnsigned
    Dism /Unmount-Image /MountDir:$MountPath /Commit

    Dism /Mount-Image /ImageFile:$WimFile /Index:1 /MountDir:$MountPath
    Dism /Image:$MountPath /Add-Driver /Driver:$DriverSource /Recurse /ForceUnsigned
    
    $ModuleDest = "$MountPath\Windows\System32\WindowsPowerShell\v1.0\Modules"
    if (!(Test-Path $ModuleDest)) { New-Item $ModuleDest -ItemType Directory -Force }
    robocopy "$ModuleSource" "$ModuleDest" /E /MT:32 | Out-Null
    Get-ChildItem -Path "$ModuleDest" -Recurse | Unblock-File
    
    Dism /Unmount-Image /MountDir:$MountPath /Commit
}

function Update-IsoAssets {
    param ([string]$ExtractPath, [hashtable]$AssetPaths)
    Write-Host "--- Phase: Updating ISO Assets ---" -ForegroundColor Yellow
    $DeployDir = New-Item -Path "$ExtractPath\deployment" -ItemType Directory -Force
    foreach ($Key in $AssetPaths.Keys) {
        if ($AssetPaths[$Key]) { Copy-Item $AssetPaths[$Key] -Destination $DeployDir -Force -Recurse }
    }
    if (Test-Path "$ExtractPath\boot\bootfix.bin") { Remove-Item "$ExtractPath\boot\bootfix.bin" -Force }
    $EfiBootDir = "$ExtractPath\efi\microsoft\boot"
    Copy-Item "$EfiBootDir\efisys_noprompt.bin" "$EfiBootDir\efisys.bin" -Force
    Copy-Item "$EfiBootDir\cdboot_noprompt.efi" "$EfiBootDir\cdboot.efi" -Force
}

function New-CustomIso {
    param ([string]$OscdimgPath, [string]$ExtractPath, [string]$DestinationIso)
    Write-Host "--- Phase: Final ISO Compilation ---" -ForegroundColor Cyan
    $EfiBin = "$ExtractPath\efi\microsoft\boot\efisys.bin"
    $EtfsBin = "$ExtractPath\boot\etfsboot.com"
    $BootData = "2#p0,e,b`"$EtfsBin`"#pEF,e,b`"$EfiBin`""
    & $OscdimgPath -m -o -u2 -udfver102 -l"Win11_Custom" -bootdata:$BootData "$ExtractPath" "$DestinationIso"
}

# --- 2. MAIN EXECUTION (Direct Logic) ---

$IsoFile = Get-ChildItem -Filter "*.iso" $IsoInputFolder | Select-Object -First 1
if (!$IsoFile) { 
    Write-Error "CRITICAL: No ISO found in $IsoInputFolder"
    return 
}
$IsoPath = $IsoFile.FullName

if ($Action -eq "Query") {
    Get-WimImageInfo -IsoPath $IsoPath
} 
elseif ($Action -eq "Process") {
    $WorkDir     = Join-Path $BaseDir "IsoBuilding"
    $ExtractDir  = Join-Path $WorkDir "Extract"
    $AddOnDir    = Join-Path $BaseDir "AddOnSoftware"
    $InvalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $EscapedInvalidChars = [regex]::Escape(-join $InvalidChars)
    if ($ISOName -match "[$EscapedInvalidChars]") {
        Write-Error "ISO Filename contains invalid characters (e.g., / \ : * ?)"
        return
    }
    $OutDir      = Join-Path $BaseDir "OutPutIso"
    $OscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"

    if (!(Test-Path $OscdimgPath)) { Write-Error "ADK Tools missing at $OscdimgPath"; return }

    $Assets = @{
        "VirtioTools" = "$AddOnDir\virtio\virtio-win-guest-tools.exe"
        "OpenSSH"     = (Get-ChildItem -Filter "OpenSSH*.msi" $AddOnDir).FullName
        "PS7"         = (Get-ChildItem -Filter "PowerShell-*.msi" $AddOnDir).FullName
        "InitScript"  = (Get-ChildItem -Filter "initial-configuration.ps1" $AddOnDir).FullName
        "Leostream"   = (Get-ChildItem -Filter "LeostreamAgentSetup*.exe" $AddOnDir).FullName
        "Intune"      = (Get-ChildItem -Filter "lcps-vdi-labs.ppkg" $AddOnDir).FullName
        "VirtioDir"   = "$AddOnDir\virtio"
    }

    Expand-WindowsIso -IsoPath $IsoPath -ExtractPath $ExtractDir
    Invoke-WimPatching -ExtractPath $ExtractDir -WorkDir $WorkDir -TargetIndex $TargetIndex `
                       -DriverSource "$AddOnDir\virtio" -ModuleSource "$AddOnDir\PowerShellModules"
    Update-IsoAssets -ExtractPath $ExtractDir -AssetPaths $Assets
    New-CustomIso -OscdimgPath $OscdimgPath -ExtractPath $ExtractDir -DestinationIso "$OutDir\$ISOName"
    
    Write-Host "`n--- SUCCESS: Custom OpenShift ISO Created ---" -ForegroundColor Green
}


#Preparation of the ENV
#Windows Imaging and Configuration Designer must be installed for creating the enrollment package for either AD or Intune, and OSCDIMG for manipulating the ISOs.
#Directory Structure, no mandatory. You can pick a different location, but the substructure must be preserved.
#New-Item -Path "C:\iso-processing" -ItemType Directory -Confirm:$false
#New-Item -Path "C:\iso-processing\AddOnSoftware" -ItemType Directory -Confirm:$false
#New-Item -Path "C:\iso-processing\InputIso" -ItemType Directory -Confirm:$false
#New-Item -Path "C:\iso-processing\IsoBuilding" -ItemType Directory -Confirm:$false
#New-Item -Path "C:\iso-processing\OutPutIso" -ItemType Directory -Confirm:$false

#Add the ISO on path "C:\iso-processing\InputIso"
#Add the iso to cd location of ISO
#.\create-win11-iso.ps1 -Action Query -IsoInputFolder "C:\iso-processing\InputIso"
#Processing the ISO
#.\create-win11-iso.ps1 -Action Process -IsoInputFolder "C:\iso-processing\InputIso" -TargetIndex 3 -ISOName "win11-25h2-cstm.iso"




#If an error happens dismounting the ISO
# Attempt commit
#Dism /Unmount-Image /MountDir:"$MountPath" /Commit
#Dism /Cleanup-Mountpoints
#Dism /Unmount-Image /MountDir:"$MountPath" /Discard
 
