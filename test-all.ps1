# Authtake - tum dogrulama testlerini calistirir
#
#   .\test-all.ps1
#
# Onkosul: sistem calisiyor olmali (.\start.ps1)
# PART 5 testi token omrunu gecici olarak kisalttigi icin ~2 dakika surer.

$suites = @(
    @{ Name = 'PART 1  Keycloak realm yapilandirmasi';        Script = 'verify-part1.ps1' },
    @{ Name = 'PART 2  Backend API + RBAC';                   Script = 'verify-part2.ps1' },
    @{ Name = 'PART 3  Frontend giris akisi + role-based UI'; Script = 'verify-part3.ps1' },
    @{ Name = 'PART 4  3rd Party servis istemcisi';           Script = 'verify-part4.ps1' },
    @{ Name = 'PART 5  Otomatik token yenileme';              Script = 'verify-part5.ps1' },
    @{ Name = 'GUVENLIK  Saldiri senaryolari';                Script = 'verify-security.ps1' }
)

$totalPass = 0
$totalFail = 0
$results = @()

foreach ($s in $suites) {
    Write-Host ("`n{0}" -f ('=' * 62)) -ForegroundColor DarkGray
    Write-Host $s.Name -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkGray

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\scripts\$($s.Script)" 2>&1
    $output | ForEach-Object { Write-Host $_ }

    $summary = $output | Select-String -Pattern '(\d+) basarili, (\d+) basarisiz' | Select-Object -Last 1
    if ($summary -and $summary.Matches.Count -gt 0) {
        $pass = [int]$summary.Matches[0].Groups[1].Value
        $fail = [int]$summary.Matches[0].Groups[2].Value
    } else {
        $pass = 0; $fail = 1
    }

    $totalPass += $pass
    $totalFail += $fail
    $results += [PSCustomObject]@{ Suite = $s.Name; Basarili = $pass; Basarisiz = $fail }
}

Write-Host ("`n{0}" -f ('=' * 62)) -ForegroundColor DarkGray
Write-Host "OZET" -ForegroundColor Cyan
Write-Host ('=' * 62) -ForegroundColor DarkGray
$results | Format-Table -AutoSize

Write-Host ("TOPLAM: {0} basarili, {1} basarisiz" -f $totalPass, $totalFail) `
    -ForegroundColor $(if ($totalFail) { 'Red' } else { 'Green' })
Write-Host ""

if ($totalFail) { exit 1 }
