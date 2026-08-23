# PART 1 dogrulama scripti - Keycloak realm yapilandirmasi
# Kullanim: .\scripts\verify-part1.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\AuthFlow.ps1"

$KC    = 'http://localhost:8080'
$REALM = 'authtake'

$script:Pass = 0
$script:Fail = 0
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }

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
    $resp = Get-ServiceToken
    Ok "Access token alindi (expires_in=$($resp.expires_in)s)"

    $claims = ConvertFrom-Jwt $resp.access_token
    Write-Host "    azp   : $($claims.azp)"
    Write-Host "    aud   : $($claims.aud -join ', ')"
    Write-Host "    roles : $($claims.realm_access.roles -join ', ')"

    # Servis hesabi 'admin' DEGIL, kendi dar rolunu tasir (en az yetki ilkesi).
    if ($claims.realm_access.roles -contains 'service-api') { Ok "Service account 'service-api' rolune sahip" }
    else { Fail "Service account'ta 'service-api' rolu yok" }

    if ($claims.realm_access.roles -notcontains 'admin') { Ok "Service account 'admin' rolunu TASIMIYOR (en az yetki)" }
    else { Fail "Service account gereksiz yere 'admin' rolune sahip" }

    if ($claims.aud -contains 'authtake-backend') { Ok "Audience 'authtake-backend' iceriyor" }
    else { Fail "Audience mapper calismiyor (aud: $($claims.aud -join ', '))" }
} catch {
    Fail "Token alinamadi: $($_.Exception.Message)"
}

Write-Host "`n=== 3) Authorization Code + PKCE (test userlari) ===" -ForegroundColor Cyan
Write-Host "    Password akisi kapali; testler de gercek tarayici akisini kullaniyor." -ForegroundColor DarkGray
foreach ($u in @(
    @{ n = 'sefo_admin'; p = 'Admin123!'; r = 'admin' },
    @{ n = 'sefo_user';  p = 'User123!';  r = 'user'  })) {
    try {
        $t = Get-UserToken -Username $u.n -Password $u.p
        $c = ConvertFrom-Jwt $t.access_token

        Ok "$($u.n) login OK - roles: $($c.realm_access.roles -join ', ')"
        if ($c.realm_access.roles -contains $u.r) { Ok "$($u.n) '$($u.r)' rolune sahip" }
        else { Fail "$($u.n) '$($u.r)' rolune sahip degil" }

        if ($t.refresh_token) { Ok "$($u.n) icin refresh token verildi" }
        else { Fail "$($u.n) icin refresh token gelmedi" }

        if ($u.n -eq 'sefo_user' -and $c.realm_access.roles -contains 'admin') {
            Fail "sefo_user admin rolune sahip olmamaliydi"
        }
    } catch {
        Fail "$($u.n) login basarisiz: $($_.Exception.Message)"
    }
}

Write-Host "`n=== 4) Kapatilan akislar gercekten kapali mi? ===" -ForegroundColor Cyan
# Public client'ta password akisi acik kalirsa PKCE'nin sagladigi koruma
# atlanabilir; kapali oldugunu dogruluyoruz.
try {
    Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; client_id = 'authtake-frontend'
                 username = 'sefo_admin'; password = 'Admin123!' } | Out-Null
    Fail "Password akisi hala ACIK - public client'ta kapali olmaliydi"
} catch {
    Ok "Password (Direct Access Grants) akisi kapali"
}

Write-Host ("`n{0} basarili, {1} basarisiz.`n" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
