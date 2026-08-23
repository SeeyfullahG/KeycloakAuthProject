# PART 4 dogrulama scripti - 3rd Party API (Client Credentials)
# Onkosul: Keycloak (docker compose up -d) VE Backend API :5000
# Kullanim: .\scripts\verify-part4.ps1

$KC  = 'http://localhost:8080'
$API = 'http://localhost:5000'
$REALM = 'authtake'
$PROJECT = Join-Path $PSScriptRoot '..\src\Authtake.ThirdPartyClient'

$script:Pass = 0
$script:Fail = 0
function Ok($m)  { Write-Host "  [OK]   $m" -ForegroundColor Green; $script:Pass++ }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }

function Get-Dotnet {
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
    if (Test-Path $fallback) { return $fallback }
    throw "dotnet bulunamadi."
}

$dotnet = Get-Dotnet

Write-Host "`n=== 0) Servisler ayakta mi? ===" -ForegroundColor Cyan
foreach ($svc in @(
    @{ n = 'Keycloak';    u = "$KC/realms/$REALM/.well-known/openid-configuration" },
    @{ n = 'Backend API'; u = "$API/api/public/hello" })) {
    try { Invoke-WebRequest $svc.u -TimeoutSec 5 -UseBasicParsing | Out-Null; Ok "$($svc.n) yanit veriyor" }
    catch { Bad "$($svc.n) ulasilamiyor: $($_.Exception.Message)" }
}
if ($script:Fail) { Write-Host "`nServisleri baslatip tekrar dene.`n" -ForegroundColor Yellow; exit 1 }

Write-Host "`n=== 1) 3rd Party istemcisi calistiriliyor ===" -ForegroundColor Cyan
# Uygulama kendi kontrollerini yapip cikis kodu dondurur: 0 = hepsi gecti.
$output = & $dotnet run --project $PROJECT --no-build 2>&1
$exitCode = $LASTEXITCODE
$text = $output -join "`n"

if ($exitCode -eq 0) { Ok "Uygulama sifir cikis koduyla tamamlandi" }
else {
    Bad "Uygulama $exitCode cikis kodu dondurdu"
    Write-Host $text -ForegroundColor DarkGray
}

Write-Host "`n=== 2) Cikti icerigi dogrulaniyor ===" -ForegroundColor Cyan
foreach ($check in @(
    @{ n = 'Client Credentials ile token alindi';        p = 'Access token alindi' },
    @{ n = 'Token authtake-3rdparty icin uretildi';      p = 'Token bu client icin uretildi' },
    @{ n = 'Audience authtake-backend iceriyor';         p = "Audience 'authtake-backend' iceriyor" },
    @{ n = 'Service account service-api rolune sahip';   p = "Service account 'service-api' rolune sahip" },
    @{ n = 'Service account admin rolu TASIMIYOR';       p = "'admin' rolunu TASIMIYOR" },
    @{ n = 'Kimlik service account olarak taniniyor';    p = 'Kimlik bir service account' },
    @{ n = 'Backend akisi client_credentials isaretledi'; p = "Backend akisi 'client_credentials'" },
    @{ n = 'Token gonderilmeyince 401 aliniyor';         p = '401 Unauthorized' },
    @{ n = 'Token onbellegi calisiyor';                  p = 'onbellekten karsilandi' })) {
    if ($text -match [regex]::Escape($check.p)) { Ok $check.n } else { Bad "$($check.n) - ciktida bulunamadi" }
}

if ($text -match '(\d+) basarili, (\d+) basarisiz') {
    $passed = [int]$matches[1]; $failed = [int]$matches[2]
    if ($failed -eq 0) { Ok "Uygulama ici kontroller: $passed basarili, 0 basarisiz" }
    else { Bad "Uygulama ici kontrollerde $failed basarisiz var" }
} else { Bad "Uygulama ozet satiri bulunamadi" }

Write-Host "`n=== 3) Negatif kontrol: yanlis client_secret ===" -ForegroundColor Cyan
# .NET yapilandirmasi ortam degiskeniyle ezilebilir (Keycloak__ClientSecret).
# Yanlis sifreyle Keycloak token vermemeli, uygulama da temiz bir hata ile durmali.
$env:Keycloak__ClientSecret = 'kesinlikle-yanlis-secret'
try {
    $badOutput = (& $dotnet run --project $PROJECT --no-build 2>&1) -join "`n"
    $badExit = $LASTEXITCODE
} finally {
    Remove-Item Env:\Keycloak__ClientSecret -ErrorAction SilentlyContinue
}

if ($badExit -ne 0) { Ok "Yanlis secret ile uygulama basarisiz cikis kodu dondurdu ($badExit)" }
else { Bad "Yanlis secret'a ragmen uygulama basarili dondu!" }

if ($badOutput -match 'Token alinamadi' -or $badOutput -match 'unauthorized_client' -or $badOutput -match 'invalid_client') {
    Ok "Hata mesaji Keycloak'in reddini aciklikla bildiriyor"
} else {
    Bad "Beklenen hata mesaji yok"
    Write-Host ($badOutput | Select-Object -First 20) -ForegroundColor DarkGray
}

Write-Host "`n=== 4) Frontend'siz dogrudan akis (curl esdegeri) ===" -ForegroundColor Cyan
# Uygulamadan bagimsiz olarak akisin kendisini de dogrulayalim.
try {
    $token = (Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'client_credentials'
                 client_id = 'authtake-3rdparty'
                 client_secret = 'thirdparty-secret-change-me-2024' }).access_token
    Ok "Keycloak dogrudan istekte de token verdi"

    $r = Invoke-WebRequest -Uri "$API/api/admin/data" -Headers @{ Authorization = "Bearer $token" } `
        -UseBasicParsing -TimeoutSec 15
    if ([int]$r.StatusCode -eq 200) { Ok "Backend service account token'i ile 200 OK dondu" }
    else { Bad "Beklenmeyen status: $($r.StatusCode)" }

    $body = $r.Content | ConvertFrom-Json
    if ($body.user.isServiceAccount) { Ok "Yanitta isServiceAccount = true" } else { Bad "isServiceAccount yanlis" }
    if ($body.user.clientId -eq 'authtake-3rdparty') { Ok "Yanitta clientId = authtake-3rdparty" } else { Bad "clientId yanlis" }
} catch {
    Bad "Dogrudan akis basarisiz: $($_.Exception.Message)"
}

Write-Host ("`n{0} basarili, {1} basarisiz.`n" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
