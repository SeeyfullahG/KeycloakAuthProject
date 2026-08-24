# Authtake - tum sistemi tek komutla baslatir
#
#   .\start.ps1
#
# Sirasiyla: Keycloak + PostgreSQL (Docker), Backend API, Frontend.
# Backend ve Frontend ayri pencerelerde acilir; kapatmak icin pencereleri kapat.
# Keycloak'i durdurmak icin: docker compose down

# Not: $ErrorActionPreference = 'Stop' KULLANILMIYOR.
# Windows PowerShell 5.1'de bir native komutun (docker, dotnet) stderr ciktisi
# yonlendirildiginde her satir ErrorRecord'a sarilir; 'Stop' altinda bu, komut
# basariyla bitse bile script'i durdurur. Hatalari cikis kodlarindan kontrol
# ediyoruz.
$root = $PSScriptRoot

function Info($m) { Write-Host "  $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  [!]  $m" -ForegroundColor Red }

function Find-Tool($name, $fallbacks) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in $fallbacks) { if (Test-Path $p) { return $p } }
    return $null
}

Write-Host "`n=== Authtake baslatiliyor ===" -ForegroundColor Cyan

# --- Onkosullar ---------------------------------------------------------
$docker = Find-Tool 'docker' @("$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe")
$dotnet = Find-Tool 'dotnet' @("$env:ProgramFiles\dotnet\dotnet.exe",
                               "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe")

if (-not $docker) { Fail "Docker bulunamadi. https://www.docker.com/products/docker-desktop/"; exit 1 }
if (-not $dotnet) { Fail ".NET 8 SDK bulunamadi. https://dotnet.microsoft.com/download/dotnet/8.0"; exit 1 }
Ok "Docker ve .NET SDK bulundu"

function Test-DockerRunning {
    & $docker info 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

if (-not (Test-DockerRunning)) {
    Info "Docker Desktop kapali, baslatiliyor..."
    $dd = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dd) { Start-Process $dd }

    for ($i = 1; $i -le 40; $i++) {
        Start-Sleep -Seconds 5
        if (Test-DockerRunning) { break }
        if ($i -eq 40) { Fail "Docker Desktop baslatilamadi."; exit 1 }
    }
}
Ok "Docker calisiyor"

# --- 1) Keycloak + PostgreSQL -------------------------------------------
Write-Host "`n[1/3] Keycloak + PostgreSQL" -ForegroundColor Cyan
Push-Location $root
try { & $docker compose up -d 2>$null | Out-Null } finally { Pop-Location }

Info "Keycloak'in hazir olmasi bekleniyor (ilk calistirmada 1-2 dk surebilir)..."
$ready = $false
for ($i = 1; $i -le 60; $i++) {
    try {
        Invoke-RestMethod 'http://localhost:8080/realms/authtake/.well-known/openid-configuration' `
            -TimeoutSec 5 | Out-Null
        $ready = $true; break
    } catch { Start-Sleep -Seconds 5 }
}
if (-not $ready) { Fail "Keycloak 5 dk icinde hazir olmadi. 'docker compose logs keycloak'"; exit 1 }
Ok "Keycloak hazir  ->  http://localhost:8080  (admin / admin)"

# --- 2) Derleme ---------------------------------------------------------
Write-Host "`n[2/3] Projeler derleniyor" -ForegroundColor Cyan
& $dotnet build "$root\AuthtakeKeycloak.sln" -v quiet --nologo 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Derleme basarisiz."; exit 1 }
Ok "Derleme tamam"

# --- 3) Backend + Frontend ----------------------------------------------
Write-Host "`n[3/3] Backend API ve Frontend" -ForegroundColor Cyan

function Start-App($title, $project) {
    Start-Process powershell -ArgumentList @(
        '-NoExit', '-Command',
        "`$host.UI.RawUI.WindowTitle='$title'; & '$dotnet' run --project '$project' --launch-profile http --no-build"
    )
}

Start-App 'Authtake Backend API (:5000)' "$root\src\Authtake.BackendApi"
Start-App 'Authtake Frontend (:5002)'    "$root\src\Authtake.Frontend"

function Wait-Url($url, $label) {
    for ($i = 1; $i -le 30; $i++) {
        try { Invoke-WebRequest $url -TimeoutSec 3 -UseBasicParsing | Out-Null; Ok $label; return $true }
        catch { Start-Sleep -Seconds 2 }
    }
    Fail "$label baslatilamadi"; return $false
}

$b = Wait-Url 'http://localhost:5000/api/public/hello' 'Backend API hazir  ->  http://localhost:5000'
$f = Wait-Url 'http://localhost:5002/'                 'Frontend hazir     ->  http://localhost:5002'

# --- Ozet ---------------------------------------------------------------
Write-Host "`n=== Sistem calisiyor ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Frontend (buradan basla) : http://localhost:5002"
Write-Host "  Backend API / Swagger    : http://localhost:5000/swagger"
Write-Host "  Keycloak admin konsolu   : http://localhost:8080   (admin / admin)"
Write-Host ""
Write-Host "  Test kullanicilari:" -ForegroundColor White
Write-Host "    sefo_admin / Admin123!   (admin + user rolleri)"
Write-Host "    sefo_user  / User123!    (yalnizca user rolu)"
Write-Host ""
Write-Host "  3rd Party servis istemcisi (kullanici olmadan token alir):" -ForegroundColor White
Write-Host "    dotnet run --project src\Authtake.ThirdPartyClient"
Write-Host ""
Write-Host "  Tum testleri calistir:" -ForegroundColor White
Write-Host "    .\test-all.ps1"
Write-Host ""

if ($b -and $f) {
    Start-Process 'http://localhost:5002'
    Info "Tarayici acildi."
}
