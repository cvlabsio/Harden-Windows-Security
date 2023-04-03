#requires -version 7.3.3
Function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
if (-NOT (Test-IsAdmin)) {
    write-host "Administrator privileges Required" -ForegroundColor Magenta
    break
}
function Confirm-WDACConfig {
    [CmdletBinding(
        HelpURI = "https://github.com/HotCakeX/Harden-Windows-Security/wiki/WDACConfig"
    )]
    Param(     
        [Parameter(Mandatory = $false, Position = 0, ParameterSetName = "set1")][switch]$ListActivePolicies,
        [Parameter(Mandatory = $false, Position = 0, ParameterSetName = "set2")][switch]$VerifyWDACStatus,
        [Parameter(Mandatory = $false)][switch]$SkipVersionCheck
    )
    $ErrorActionPreference = 'Stop'         

    
    # Make sure the latest version of the module is installed and if not, automatically update it, clean up any old versions
    if (-NOT $SkipVersionCheck) {
        $currentversion = (Test-modulemanifest "$psscriptroot\WDACConfig.psd1").Version.ToString()
        try {
            $latestversion = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/HotCakeX/Harden-Windows-Security/main/WDACConfig/version.txt"
        }
        catch {
            Write-Error "Couldn't verify if the latest version of the module is installed, please check your Internet connection. You can optionally bypass the online check by using -SkipVersionCheck parameter."
            break
        }
        if (-NOT ($currentversion -eq $latestversion)) {
            Write-Host "The currently installed module's version is $currentversion while the latest version is $latestversion - Auto Updating the module now and will run your command after that 💓"
            Remove-Module -Name WDACConfig -Force
            try {
                Uninstall-Module -Name WDACConfig -AllVersions -Force -ErrorAction Stop
                Install-Module -Name WDACConfig -RequiredVersion $latestversion -Force              
                Import-Module -Name WDACConfig -RequiredVersion $latestversion -Force -Global
            }
            catch {
                Install-Module -Name WDACConfig -RequiredVersion $latestversion -Force
                Import-Module -Name WDACConfig -RequiredVersion $latestversion -Force -Global
            }
            
        }
    }


    if ($ListActivePolicies) {
        Write-host "`nDisplaying non-System WDAC Policies:" -ForegroundColor Cyan
        (CiTool -lp -json | ConvertFrom-Json).Policies | Where-Object { $_.IsSystemPolicy -ne "True" }
    }
    if ($VerifyWDACStatus) {
        Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard | Select-Object -Property *codeintegrity* | Format-List
        Write-host "2 -> Enforced`n1 -> Audit mode`n0 -> Disabled/Not running`n" -ForegroundColor Cyan
    }
    <#
.SYNOPSIS
Show the status of WDAC on the system and lists the current deployed policies and shows details about each of them

.LINK
https://github.com/HotCakeX/Harden-Windows-Security/wiki/WDACConfig

.DESCRIPTION
Using official Microsoft methods, Show the status of WDAC on the system and lists the current deployed policies and shows details about each of them (Windows Defender Application Control)

.COMPONENT
Windows Defender Application Control

.FUNCTIONALITY
Using official Microsoft methods, Show the status of WDAC on the system and lists the current deployed policies and shows details about each of them (Windows Defender Application Control)

.PARAMETER VerifyWDACStatus
Shows the status of WDAC on the system

.PARAMETER ListActivePolicies
lists the current deployed policies and shows details about each of them

.PARAMETER SkipVersionCheck
Can be used with any parameter to bypass the online version check - only to be used in rare cases

#> 
}

# Set PSReadline tab completion to complete menu for easier access to available parameters - Only for the current session
Set-PSReadlineKeyHandler -Key Tab -Function MenuComplete