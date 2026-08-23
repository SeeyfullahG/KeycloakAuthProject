# Guvenlik dogrulama scripti - saldiri senaryolari
# Onkosul: Keycloak (docker compose up -d) VE Backend API :5000
# Kullanim: .\scripts\verify-security.ps1
#
# Diger script'ler "dogru kullanimda dogru calisiyor mu" sorusunu test eder.
# Bu script "kotu niyetli biri ne yapabilir" sorusunu test eder.

. "$PSScriptRoot\lib\AuthFlow.ps1"

$KC    = 'http://localhost:8080'
$API   = 'http://localhost:5000'
$REALM = 'authtake'

$script:Pass = 0
$script:Fail = 0
function Ok($m)  { Write-Host "  [OK]   $m" -ForegroundColor Green; $script:Pass++ }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }

function Get-ApiStatus($token, $path = '/api/admin/data') {
    $headers = @{}
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    try {
        $r = Invoke-WebRequest -Uri "$API$path" -Headers $headers -UseBasicParsing -TimeoutSec 15
        return [int]$r.StatusCode
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        throw
    }
}

function ConvertTo-B64Url([string] $text) {
    ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($text))
}

# Bir JWT'nin govdesini degistirip parcalari yeniden birlestirir. Imza ESKI
# haliyle kalir - saldirganin yapabilecegi tam olarak budur, cunku imzayi
# yeniden uretmek icin Keycloak'in ozel anahtarina ihtiyaci var.
function New-TamperedToken([string] $Token, [scriptblock] $Modify) {
    $parts = $Token.Split('.')
    $claims = ConvertFrom-Jwt $Token
    & $Modify $claims
    $payload = ConvertTo-B64Url ($claims | ConvertTo-Json -Depth 20 -Compress)
    return "$($parts[0]).$payload.$($parts[2])"
}

Write-Host "`n=== 0) Servisler ve gecerli token ===" -ForegroundColor Cyan
try {
    $service = (Get-ServiceToken).access_token
    if ((Get-ApiStatus $service) -eq 200) { Ok "Gecerli servis token'i 200 aliyor (kontrol noktasi)" }
    else { Bad "Gecerli token calismiyor - once diger testleri kontrol et"; exit 1 }
} catch {
    Bad "Baslangic basarisiz: $($_.Exception.Message)"
    Write-Host "Keycloak ve Backend API calisiyor mu?`n" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n=== 1) Token sahteciligi ===" -ForegroundColor Cyan

# 1a) Imzayi boz
$parts = $service.Split('.')
$flipped = if ($parts[2][-1] -ne 'A') { 'A' } else { 'B' }
$badSignature = "$($parts[0]).$($parts[1]).$($parts[2].Substring(0, $parts[2].Length - 1))$flipped"
if ((Get-ApiStatus $badSignature) -eq 401) { Ok "Imzasi bozulmus token reddedildi" }
else { Bad "Imzasi bozulmus token KABUL EDILDI" }

# 1b) Rolleri sisir - "token'in icine admin yazarim olur biter" saldirisi
$escalated = New-TamperedToken $service {
    param($c)
    $c.realm_access.roles = @('admin', 'superuser', 'root')
}
if ((Get-ApiStatus $escalated) -eq 401) { Ok "Rolleri degistirilmis token reddedildi (yetki yukseltme onlendi)" }
else { Bad "Rol yukseltme BASARILI OLDU - kritik acik" }

# 1c) Suresi gecmise cekilmis token
$expired = New-TamperedToken $service { param($c) $c.exp = 1000000000 }
if ((Get-ApiStatus $expired) -eq 401) { Ok "Suresi degistirilmis token reddedildi" }
else { Bad "Suresi degistirilmis token kabul edildi" }
Note "Not: govde degisince imza da bozuluyor; bu, sure dolmasinin ayri bir testi degildir."

# 1d) alg=none: "imza kontrolu yapma" diyen klasik saldiri
$algNone = "$(ConvertTo-B64Url '{"alg":"none","typ":"JWT"}').$($parts[1])."
if ((Get-ApiStatus $algNone) -eq 401) { Ok "alg=none saldirisi reddedildi" }
else { Bad "alg=none KABUL EDILDI - kritik acik" }

Write-Host "`n=== 2) Yabanci ve yanlis tipte token ===" -ForegroundColor Cyan

# 2a) Baska realm'den alinmis, kendi icinde gecerli imzali token
try {
    $foreign = (Invoke-RestMethod -Method Post -Uri "$KC/realms/master/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; client_id = 'admin-cli'
                 username = 'admin'; password = 'admin' }).access_token
    if ((Get-ApiStatus $foreign) -eq 401) { Ok "Baska realm'in token'i reddedildi (issuer dogrulamasi)" }
    else { Bad "Yabanci realm token'i kabul edildi" }
} catch { Bad "Yabanci realm testi calistirilamadi: $($_.Exception.Message)" }

# 2b) id_token, access token yerine kullanilamamali
try {
    $tokens = Get-UserToken -Username 'sefo_admin' -Password 'Admin123!'
    if ((Get-ApiStatus $tokens.id_token) -eq 401) { Ok "id_token access token yerine kullanilamiyor" }
    else { Bad "id_token access token olarak kabul edildi" }
} catch { Bad "id_token testi calistirilamadi: $($_.Exception.Message)" }

Write-Host "`n=== 3) Yetkilendirme siniri ===" -ForegroundColor Cyan
try {
    $userToken = (Get-UserToken -Username 'sefo_user' -Password 'User123!').access_token
    if ((Get-ApiStatus $userToken) -eq 403) { Ok "Rolu yetersiz kullanici 403 aliyor (401 degil)" }
    else { Bad "sefo_user icin beklenen 403 gelmedi" }
    if ((Get-ApiStatus $userToken '/api/hello/secure') -eq 200) { Ok "Ayni kullanici yetkili endpoint'e girebiliyor" }
    else { Bad "sefo_user /api/hello/secure'a giremiyor" }
} catch { Bad "Yetki siniri testi calistirilamadi: $($_.Exception.Message)" }

Write-Host "`n=== 4) Kapatilmis akislar ===" -ForegroundColor Cyan
try {
    Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; client_id = 'authtake-frontend'
                 username = 'sefo_admin'; password = 'Admin123!' } | Out-Null
    Bad "Public client'ta password akisi ACIK"
} catch { Ok "Public client'ta password akisi kapali" }

try {
    Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'client_credentials'; client_id = 'authtake-frontend' } | Out-Null
    Bad "Public client client_credentials alabiliyor"
} catch { Ok "Public client client_credentials alamiyor" }

Write-Host "`n=== 5) Refresh token rotasyonu ===" -ForegroundColor Cyan
# revokeRefreshToken=true: her yenilemede eski refresh token gecersizlesir.
# Calinan bir refresh token'in kullanim omru boylece tek seferle sinirlanir.
try {
    $first = Get-UserToken -Username 'sefo_admin' -Password 'Admin123!'
    $refreshBody = @{ grant_type = 'refresh_token'; client_id = 'authtake-frontend'
                      refresh_token = $first.refresh_token }

    $second = Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' -Body $refreshBody
    Ok "Refresh token ile yeni access token alindi"

    if ($second.refresh_token -ne $first.refresh_token) { Ok "Yenilemede YENI refresh token verildi (rotasyon)" }
    else { Bad "Ayni refresh token geri dondu - rotasyon kapali" }

    try {
        Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
            -ContentType 'application/x-www-form-urlencoded' -Body $refreshBody | Out-Null
        Bad "ESKI refresh token hala kullanilabiliyor"
    } catch { Ok "Eski refresh token ikinci kez kullanilamadi" }
} catch { Bad "Rotasyon testi calistirilamadi: $($_.Exception.Message)" }

Write-Host "`n=== 6) Brute force korumasi ===" -ForegroundColor Cyan
# Yanlis sifreyle ust uste denedigimizde hesap gecici olarak kilitlenmeli.
# Test sonunda kilidi admin API ile aciyoruz ki diger testler etkilenmesin.
$adminToken = $null
$lockedUserId = $null
try {
    $adminToken = (Invoke-RestMethod -Method Post -Uri "$KC/realms/master/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; client_id = 'admin-cli'
                 username = 'admin'; password = 'admin' }).access_token

    $adminHeaders = @{ Authorization = "Bearer $adminToken" }
    $lockedUserId = (Invoke-RestMethod -Uri "$KC/admin/realms/$REALM/users?username=sefo_user&exact=true" `
        -Headers $adminHeaders)[0].id

    for ($i = 1; $i -le 6; $i++) {
        try { Get-UserToken -Username 'sefo_user' -Password "yanlis-sifre-$i" | Out-Null } catch { }
    }

    $status = Invoke-RestMethod -Uri "$KC/admin/realms/$REALM/attack-detection/brute-force/users/$lockedUserId" `
        -Headers $adminHeaders

    # Not: numFailures'in failureFactor'a (5) ulasmasini beklemiyoruz. Keycloak'in
    # "hizli giris denetimi" (quickLoginCheckMilliSeconds) ard arda cok hizli gelen
    # denemeleri ayrica cezalandirir ve hesabi daha az denemede kilitleyebilir.
    # Onemli olan sayacin islemesi ve hesabin kilitlenmesi.
    if ($status.numFailures -gt 0) { Ok "Basarisiz denemeler sayiliyor (numFailures=$($status.numFailures))" }
    else { Bad "Basarisiz denemeler hic sayilmiyor" }

    if ($status.disabled) { Ok "Hesap gecici olarak kilitlendi (brute force korumasi aktif)" }
    else { Bad "Hesap kilitlenmedi - brute force korumasi calismiyor" }
} catch {
    Bad "Brute force testi calistirilamadi: $($_.Exception.Message)"
} finally {
    # Kilidi mutlaka ac - aksi halde diger script'ler 15 dk boyunca calismaz.
    if ($adminToken -and $lockedUserId) {
        try {
            Invoke-RestMethod -Method Delete `
                -Uri "$KC/admin/realms/$REALM/attack-detection/brute-force/users/$lockedUserId" `
                -Headers @{ Authorization = "Bearer $adminToken" } | Out-Null
            Ok "Test sonrasi hesap kilidi acildi"
        } catch { Bad "Kilit acilamadi! sefo_user 15 dk kilitli kalabilir: $($_.Exception.Message)" }
    }
}

Write-Host "`n=== 7) Bilinen davranis: cikis access token'i iptal etmez ===" -ForegroundColor Cyan
# Bu bir acik degil, JWT'nin dogasi: API her istekte Keycloak'a sormaz, imzaya
# bakar. Test burada, davranis sessizce degisirse fark edelim diye duruyor.
try {
    $session = Get-UserToken -Username 'sefo_admin' -Password 'Admin123!'
    $before = Get-ApiStatus $session.access_token
    Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/logout" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ client_id = 'authtake-frontend'; refresh_token = $session.refresh_token } | Out-Null

    $after = Get-ApiStatus $session.access_token
    if ($before -eq 200 -and $after -eq 200) {
        Ok "Cikis sonrasi access token suresi dolana kadar gecerli (beklenen davranis)"
        Note "Azaltici etken: 15 dakikalik kisa omur. Aninda iptal gerekiyorsa token introspection gerekir."
    } else { Bad "Beklenmeyen davranis: cikis oncesi $before, sonrasi $after" }

    try {
        Invoke-RestMethod -Method Post -Uri "$KC/realms/$REALM/protocol/openid-connect/token" `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{ grant_type = 'refresh_token'; client_id = 'authtake-frontend'
                     refresh_token = $session.refresh_token } | Out-Null
        Bad "Cikistan sonra refresh token hala calisiyor"
    } catch { Ok "Cikis refresh token'i gercekten iptal etti" }
} catch { Bad "Cikis testi calistirilamadi: $($_.Exception.Message)" }

Write-Host ("`n{0} basarili, {1} basarisiz.`n" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
