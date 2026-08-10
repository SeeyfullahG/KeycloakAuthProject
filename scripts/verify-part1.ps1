# PART 1 dogrulama scripti
# Kullanim: .\scripts\verify-part1.ps1

$ErrorActionPreference = 'Stop'
$KC     = 'http://localhost:8080'
$REALM  = 'authtake'
$TP_ID  = 'authtake-3rdparty'
$TP_SEC = 'thirdparty-secret-change-me-2024'

function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }

Write-Host "`n=== 1) Keycloak ayakta mi? ===" -ForegroundColor Cyan
try {
    Invoke-RestMethod "$KC/realms/$REALM/.well-known/openid-configuration" | Out-Null
    Ok "Realm '$REALM' discovery endpoint yanit veriyor"
} catch {
    Fail "Keycloak'a ulasilamadi: $($_.Exception.Message)"
    exit 1
}

Write-Host "`n=== 2) Client Credentials Flow (3rd Party) ===" -ForegroundColor Cyan
try {
    $resp = Invoke-RestMethod -Method Post `
        -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            grant_type    = 'client_credentials'
            client_id     = $TP_ID
            client_secret = $TP_SEC
        }
    Ok "Access token alindi (expires_in=$($resp.expires_in)s)"

    # JWT payload decode
    $payload = $resp.access_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4) { $payload += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json

    Write-Host "    azp   : $($claims.azp)"
    Write-Host "    aud   : $($claims.aud -join ', ')"
    Write-Host "    roles : $($claims.realm_access.roles -join ', ')"

    if ($claims.realm_access.roles -contains 'admin') { Ok "Service account 'admin' rolune sahip" }
    else { Fail "Service account'ta 'admin' rolu yok" }

    if ($claims.aud -contains 'authtake-backend') { Ok "Audience 'authtake-backend' iceriyor" }
    else { Fail "Audience mapper calismiyor (aud: $($claims.aud -join ', '))" }
} catch {
    Fail "Token alinamadi: $($_.Exception.Message)"
}

Write-Host "`n=== 3) Password Flow (test userlari) ===" -ForegroundColor Cyan
foreach ($u in @(
    @{ n='sefo_admin'; p='Admin123!'; r='admin' },
    @{ n='sefo_user';  p='User123!';  r='user'  })) {
    try {
        $t = Invoke-RestMethod -Method Post `
            -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{
                grant_type = 'password'
                client_id  = 'authtake-frontend'
                username   = $u.n
                password   = $u.p
                scope      = 'openid profile email'
            }
        $pl = $t.access_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        while ($pl.Length % 4) { $pl += '=' }
        $c = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pl)) | ConvertFrom-Json
        Ok "$($u.n) login OK - roles: $($c.realm_access.roles -join ', ')"
        if ($c.realm_access.roles -notcontains $u.r) { Fail "$($u.n) '$($u.r)' rolune sahip degil" }
        if ($u.n -eq 'sefo_user' -and $c.realm_access.roles -contains 'admin') {
            Fail "sefo_user admin rolune sahip olmamaliydi"
        }
    } catch {
        Fail "$($u.n) login basarisiz: $($_.Exception.Message)"
    }
}

Write-Host "`nPART 1 dogrulamasi tamamlandi.`n" -ForegroundColor Cyan
