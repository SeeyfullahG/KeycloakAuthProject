# PART 2 dogrulama scripti - Backend API endpoint + RBAC testleri
# Onkosul: docker compose up -d  VE  dotnet run --project src/Authtake.BackendApi
# Kullanim: .\scripts\verify-part2.ps1

$KC     = 'http://localhost:8080'
$API    = 'http://localhost:5000'
$REALM  = 'authtake'

$script:Pass = 0
$script:Fail = 0
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green; $script:Pass++ }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }

function Get-UserToken($u, $p) {
    (Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type='password'; client_id='authtake-frontend'
                 username=$u; password=$p; scope='openid profile email' }).access_token
}

function Get-ServiceToken {
    (Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type='client_credentials'; client_id='authtake-3rdparty'
                 client_secret='thirdparty-secret-change-me-2024' }).access_token
}

# Beklenen HTTP status'u dogrular, yanit govdesini geri dondurur.
# Not: Windows PowerShell 5.1'de -SkipHttpErrorCheck yok ve 4xx/5xx exception
# firlatir; status ile govdeyi exception'daki WebResponse'tan okumamiz gerekiyor.
function Invoke-Api($path, $token) {
    $headers = @{ 'Accept' = 'application/json' }
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    try {
        $r = Invoke-WebRequest -Uri "$API$path" -Headers $headers -TimeoutSec 15 -UseBasicParsing
        return @{ Status = [int]$r.StatusCode; Body = $r.Content }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) { throw }
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd(); $reader.Close()
        return @{ Status = [int]$resp.StatusCode; Body = $body }
    }
}

function Test-Endpoint($label, $path, $token, $expected) {
    try { $r = Invoke-Api $path $token }
    catch { Bad "$label -> istek basarisiz: $($_.Exception.Message)"; return $null }

    if ($r.Status -eq $expected) { Ok "$label -> $($r.Status) (beklenen $expected)" }
    else { Bad "$label -> $($r.Status), beklenen $expected. Govde: $($r.Body)" }
    try { return $r.Body | ConvertFrom-Json } catch { return $null }
}

Write-Host "`n=== Token'lar aliniyor ===" -ForegroundColor Cyan
try {
    $adminTok = Get-UserToken 'sefo_admin' 'Admin123!'
    $userTok  = Get-UserToken 'sefo_user'  'User123!'
    $svcTok   = Get-ServiceToken
    Ok "sefo_admin / sefo_user / service-account token'lari alindi"
} catch {
    Bad "Keycloak'tan token alinamadi: $($_.Exception.Message)"
    Write-Host "Keycloak calisiyor mu? 'docker compose ps'" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n=== 1) /api/public/hello - token gerektirmez ===" -ForegroundColor Cyan
$r = Test-Endpoint 'anonim' '/api/public/hello' $null 200
if ($r -and $r.message) { Ok "message alani mevcut: '$($r.message)'" } else { Bad "message alani yok" }
Test-Endpoint 'token ile' '/api/public/hello' $userTok 200 | Out-Null

Write-Host "`n=== 2) /api/hello/secure - login gerekli ===" -ForegroundColor Cyan
Test-Endpoint 'token YOK'      '/api/hello/secure' $null       401 | Out-Null
Test-Endpoint 'bozuk token'    '/api/hello/secure' 'not.a.jwt' 401 | Out-Null
$r = Test-Endpoint 'sefo_user' '/api/hello/secure' $userTok    200
if ($r) {
    if ($r.user.username -eq 'sefo_user') { Ok "user.username claim'den geldi: $($r.user.username)" }
    else { Bad "user.username yanlis: $($r.user.username)" }
    if ($r.user.email)          { Ok "user.email: $($r.user.email)" } else { Bad "user.email bos" }
    if ($r.user.id)             { Ok "user.id (sub): $($r.user.id)" } else { Bad "user.id bos" }
    if ($r.user.name)           { Ok "user.name: $($r.user.name)" } else { Bad "user.name bos" }
    if ($r.user.roles -contains 'user') { Ok "user.roles: $($r.user.roles -join ', ')" } else { Bad "roles eksik" }
    if ($r.timestamp)           { Ok "timestamp mevcut" } else { Bad "timestamp yok" }
}
Test-Endpoint 'sefo_admin' '/api/hello/secure' $adminTok 200 | Out-Null

Write-Host "`n=== 3) /api/admin/data - sadece admin rolu ===" -ForegroundColor Cyan
$r = Test-Endpoint 'token YOK' '/api/admin/data' $null 401
if ($r) {
    if ($r.error -eq 'Unauthorized' -and $r.status -eq 401 -and $r.timestamp) {
        Ok "401 hata govdesi standart formatta (error/message/status/timestamp)"
    } else { Bad "401 govdesi beklenen formatta degil: $($r | ConvertTo-Json -Compress)" }
}

$r = Test-Endpoint 'sefo_user (rol yok)' '/api/admin/data' $userTok 403
if ($r) {
    if ($r.error -eq 'Forbidden' -and $r.status -eq 403) {
        Ok "403 hata govdesi standart formatta"
    } else { Bad "403 govdesi beklenen formatta degil: $($r | ConvertTo-Json -Compress)" }
}

$r = Test-Endpoint 'sefo_admin' '/api/admin/data' $adminTok 200
if ($r) {
    if ($r.user.roles -contains 'admin') { Ok "admin rolu yanitta: $($r.user.roles -join ', ')" } else { Bad "admin rolu yok" }
    if ($r.data.records.Count -gt 0)     { Ok "data.records dondu ($($r.data.records.Count) kayit)" } else { Bad "records bos" }
    if ($r.data.accessedVia -eq 'authorization_code') { Ok "accessedVia = authorization_code" } else { Bad "accessedVia: $($r.data.accessedVia)" }
}

Write-Host "`n=== 4) Senaryo 3: 3rd Party service-to-service ===" -ForegroundColor Cyan
$r = Test-Endpoint '3rd party service account' '/api/admin/data' $svcTok 200
if ($r) {
    if ($r.user.isServiceAccount)                { Ok "isServiceAccount = true" } else { Bad "service account olarak taninmadi" }
    if ($r.user.clientId -eq 'authtake-3rdparty'){ Ok "clientId = $($r.user.clientId)" } else { Bad "clientId: $($r.user.clientId)" }
    if ($r.data.accessedVia -eq 'client_credentials') { Ok "accessedVia = client_credentials" } else { Bad "accessedVia: $($r.data.accessedVia)" }
}

Write-Host "`n=== 5) Audience dogrulamasi ===" -ForegroundColor Cyan
# Sadece 'account' audience'i olan bir token uretip reddedildigini dogrula.
try {
    $wrong = (Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type='password'; client_id='authtake-frontend'
                 username='sefo_admin'; password='Admin123!'
                 scope='openid'; audience='account' }).access_token
    $pl = $wrong.Split('.')[1].Replace('-','+').Replace('_','/'); while ($pl.Length % 4) { $pl += '=' }
    $aud = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pl)) | ConvertFrom-Json).aud
    Write-Host "    (uretilen token aud: $($aud -join ', '))"
    if ($aud -contains 'authtake-backend') {
        Ok "Bu realm her token'a authtake-backend audience'i ekliyor - negatif test atlandi"
    } else {
        Test-Endpoint 'yanlis audience' '/api/hello/secure' $wrong 401 | Out-Null
    }
} catch { Bad "audience testi calistirilamadi: $($_.Exception.Message)" }

Write-Host ("`n{0} basarili, {1} basarisiz.`n" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
