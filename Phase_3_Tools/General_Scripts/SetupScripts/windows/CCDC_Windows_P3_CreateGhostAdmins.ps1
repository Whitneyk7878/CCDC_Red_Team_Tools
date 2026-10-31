#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates 100 local administrator accounts with random hex usernames.
.DESCRIPTION
    Generates 100 accounts named usr_<8hexchars>, each with a random
    complex password and added to the local Administrators group.
    Logs all created credentials to a file in the script directory.
    PS 5.1 compatible -- no PS 7+ syntax.
#>

param(
    [int]$Count = 100,
    [string]$LogPath = "$PSScriptRoot\ghost_admins.txt"
)

$ErrorActionPreference = 'Stop'

function New-HexName {
    $bytes = New-Object byte[] 4
    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
    $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    return 'usr_' + $hex
}

function New-ComplexPassword {
    # PS 5.1: nested functions cannot close over parent locals, so all logic is inlined here
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghjkmnpqrstuvwxyz'
    $digits  = '23456789'
    $special = '!@#$%^&*()-_=+'
    $all     = $upper + $lower + $digits + $special

    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $buf = New-Object byte[] 1

    $chars = New-Object char[] 14

    # Guarantee one character from each required class
    $required = @($upper, $lower, $digits, $special)
    for ($i = 0; $i -lt 4; $i++) {
        $cs = $required[$i]
        do { $rng.GetBytes($buf) } while ($buf[0] -ge (256 - (256 % $cs.Length)))
        $chars[$i] = $cs[$buf[0] % $cs.Length]
    }

    # Fill remaining positions from full set
    for ($i = 4; $i -lt 14; $i++) {
        do { $rng.GetBytes($buf) } while ($buf[0] -ge (256 - (256 % $all.Length)))
        $chars[$i] = $all[$buf[0] % $all.Length]
    }

    # Fisher-Yates shuffle
    for ($i = 13; $i -gt 0; $i--) {
        do { $rng.GetBytes($buf) } while ($buf[0] -ge (256 - (256 % ($i + 1))))
        $j = $buf[0] % ($i + 1)
        $tmp = $chars[$i]
        $chars[$i] = $chars[$j]
        $chars[$j] = $tmp
    }

    return -join $chars
}

$results = New-Object System.Collections.ArrayList
$created = 0
$skipped = 0

Write-Host "[*] Creating $Count ghost admin accounts..."

for ($n = 0; $n -lt $Count; $n++) {
    # Retry up to 5 times on name collision
    $name = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $candidate = New-HexName
        $exists = $false
        try { Get-LocalUser -Name $candidate -ErrorAction Stop | Out-Null; $exists = $true } catch {}
        if (-not $exists) {
            $name = $candidate
            break
        }
    }

    if (-not $name) {
        Write-Warning "Could not generate unique name after 5 attempts -- skipping slot $n"
        $skipped++
        continue
    }

    $pass = New-ComplexPassword
    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force

    try {
        New-LocalUser -Name $name `
                      -Password $secPass `
                      -FullName '' `
                      -Description '' `
                      -PasswordNeverExpires `
                      -AccountNeverExpires | Out-Null

        Add-LocalGroupMember -Group 'Administrators' -Member $name

        $null = $results.Add([pscustomobject]@{ Username = $name; Password = $pass })
        $created++

        if ($n % 10 -eq 9) {
            Write-Host "    $created accounts created so far..."
        }
    }
    catch {
        Write-Warning "Failed to create $name -- $($_.Exception.Message)"
        $skipped++
    }
}

# Write log
try {
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add('Ghost Admin Credentials')
    $null = $lines.Add('Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $null = $lines.Add('Machine:   ' + $env:COMPUTERNAME)
    $null = $lines.Add(('-' * 50))
    foreach ($r in $results) {
        $null = $lines.Add($r.Username + '  ' + $r.Password)
    }
    $lines | Set-Content -Path $LogPath -Encoding ASCII
    Write-Host "[+] Credentials written to: $LogPath"
}
catch {
    Write-Warning "Could not write log file -- $($_.Exception.Message)"
    Write-Host "[!] Dumping credentials to console instead:"
    foreach ($r in $results) {
        Write-Host "  $($r.Username)  $($r.Password)"
    }
}

Write-Host "[+] Done. Created: $created  Skipped: $skipped"
