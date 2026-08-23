# PART 3 dogrulama scripti - Blazor frontend login akisi ve role-based UI
# Onkosul: Keycloak (docker compose up -d), Backend API :5000, Frontend :5002
# Kullanim: .\scripts\verify-part3.ps1
#
# Script gercek bir tarayici gibi davranir: login endpoint'ine gider, Keycloak'a
# yonlendirilir, giris formunu doldurur, geri donen oturum cookie'siyle korumali
# sayfalari ister.
#
# HTTP ve cookie yardimcilari ortak kutuphanede; oradaki aciklamalar bu
# script'in neden Invoke-WebRequest yerine HttpWebRequest kullandigini anlatir.
. "$PSScriptRoot\lib\AuthFlow.ps1"

$FE = 'http://localhost:5002'
$KC = 'http://localhost:8080'

$script:Pass = 0
$script:Fail = 0
function Ok($m)  { Write-Host "  [OK]   $m" -ForegroundColor Green; $script:Pass++ }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }

# Keycloak giris formunu doldurup gonderir; olusan oturumu (cookie deposu) dondurur.
function Invoke-KeycloakLogin($username, $password) {
    $jar = New-Jar

    # 1) Login endpoint'i bizi Keycloak'a atmali
    $login = Send-Request "$FE/authentication/login" $jar
    if ($login.Uri -notlike "$KC/*") { throw "Keycloak'a yonlendirilmedi. Gidilen adres: $($login.Uri)" }

    # 2) Giris formunun action adresini bul
    if ($login.Content -notmatch 'action="([^"]+)"') { throw "Keycloak giris formu bulunamadi" }
    $action = [System.Net.WebUtility]::HtmlDecode($matches[1])

    # 3) Kullanici adi/sifre gonder -> Keycloak bizi /signin-oidc'e dondurur,
    #    frontend kodu token'a cevirip oturum cookie'sini yazar.
    $form = 'username={0}&password={1}&credentialId=' -f
        [Uri]::EscapeDataString($username), [Uri]::EscapeDataString($password)
    $post = Send-Request $action $jar 'POST' $form

    if ($post.Uri -notlike "$FE/*") { throw "Uygulamaya donulemedi. Kalinan adres: $($post.Uri)" }
    return @{ Jar = $jar; FinalUri = $post.Uri; Content = $post.Content }
}

Write-Host "`n=== 0) Servisler ayakta mi? ===" -ForegroundColor Cyan
foreach ($svc in @(
    @{ n = 'Keycloak';    u = "$KC/realms/authtake/.well-known/openid-configuration" },
    @{ n = 'Backend API'; u = 'http://localhost:5000/api/public/hello' },
    @{ n = 'Frontend';    u = "$FE/" })) {
    $r = Send-Request $svc.u (New-Jar)
    if ($r.Status -eq 200) { Ok "$($svc.n) yanit veriyor" } else { Bad "$($svc.n): $($r.Status)" }
}
if ($script:Fail) { Write-Host "`nServisleri baslatip tekrar dene.`n" -ForegroundColor Yellow; exit 1 }

Write-Host "`n=== 1) Giris yapmamis ziyaretci ===" -ForegroundColor Cyan
$anon = New-Jar
$landing = Send-Request "$FE/" $anon
if ($landing.Status -eq 200)             { Ok "Ana sayfa aciliyor (200)" } else { Bad "Ana sayfa: $($landing.Status)" }
if ($landing.Content -match 'Giris Yap') { Ok "'Giris Yap' butonu gorunuyor" } else { Bad "'Giris Yap' butonu yok" }
if ($landing.Content -notmatch 'href="/admin"') { Ok "Admin linki gizli" } else { Bad "Admin linki ziyaretciye gorunuyor" }

$prof = Send-Request "$FE/profile" $anon
if ($prof.Uri -like "$KC/*") { Ok "/profile korumali: Keycloak giris sayfasina yonlendirdi" }
else { Bad "/profile yonlendirmedi, gidilen: $($prof.Uri)" }

Write-Host "`n=== 2) PKCE ve flow parametreleri ===" -ForegroundColor Cyan
foreach ($check in @(
    @{ n = 'response_type=code (Authorization Code flow)'; p = 'response_type=code' },
    @{ n = 'client_id=authtake-frontend';                  p = 'client_id=authtake-frontend' },
    @{ n = 'code_challenge (PKCE aktif)';                  p = 'code_challenge=' },
    @{ n = 'code_challenge_method=S256';                   p = 'code_challenge_method=S256' },
    @{ n = 'scope=openid';                                 p = 'scope=openid' })) {
    if ($prof.Uri -match [regex]::Escape($check.p)) { Ok $check.n } else { Bad "$($check.n) yok" }
}

Write-Host "`n=== 3) sefo_user girisi (admin DEGIL) ===" -ForegroundColor Cyan
try {
    $u = Invoke-KeycloakLogin 'sefo_user' 'User123!'
    Ok "Giris tamamlandi, uygulamaya donuldu"

    $h = Send-Request "$FE/" $u.Jar
    # Not: 'sefo_user' metni giris yapmamis ana sayfadaki test kullanici
    # tablosunda da geciyor; oturumun gercekten acildigini karsilama mesajindan
    # anliyoruz.
    if ($h.Content -match 'Hos geldin')    { Ok "Karsilama mesaji geldi (oturum acik)" } else { Bad "Oturum acilmamis" }
    if ($h.Content -match 'Cikis Yap')     { Ok "'Cikis Yap' butonu geldi" } else { Bad "'Cikis Yap' yok" }
    if ($h.Content -match 'tile--locked')  { Ok "Admin karti KILITLI gorunuyor" } else { Bad "Admin karti kilitli degil" }
    if ($h.Content -notmatch 'href="/admin"') { Ok "Admin linki menude yok" } else { Bad "Admin linki gorunuyor!" }

    $p = Send-Request "$FE/profile" $u.Jar
    if ($p.Status -eq 200)                            { Ok "/profile aciliyor" } else { Bad "/profile: $($p.Status)" }
    if ($p.Content -match 'sefo_user@authtake.local') { Ok "Token'dan e-posta okundu" } else { Bad "E-posta gorunmuyor" }
    if ($p.Content -match 'rolun yok')                { Ok "Profil 'admin rolun yok' diyor" } else { Bad "Rol uyarisi yok" }

    # Asil test: linki gizlemek yetmez, adresi elle yazinca da girememeli.
    $a = Send-Request "$FE/admin" $u.Jar
    if ($a.Content -match '403') { Ok "/admin adresi elle yazildi -> 403 sayfasi" } else { Bad "/admin engellenmedi! Status: $($a.Status)" }

    # Frontend uzerinden Backend API cagrilari
    $t1 = Send-Request "$FE/api-test?call=admin" $u.Jar
    if ($t1.Content -match '403 Forbidden')     { Ok "API testi: /api/admin/data -> 403 Forbidden" } else { Bad "API testi 403 dondurmedi" }
    $t2 = Send-Request "$FE/api-test?call=secure" $u.Jar
    if ($t2.Content -match '200 OK')            { Ok "API testi: /api/hello/secure -> 200 OK" } else { Bad "API testi secure basarisiz" }
    $t3 = Send-Request "$FE/api-test?call=notoken" $u.Jar
    if ($t3.Content -match '401 Unauthorized')  { Ok "API testi: token gonderilmeyince -> 401" } else { Bad "API testi 401 dondurmedi" }
} catch { Bad "sefo_user akisi basarisiz: $($_.Exception.Message)" }

Write-Host "`n=== 4) sefo_admin girisi ===" -ForegroundColor Cyan
try {
    $a = Invoke-KeycloakLogin 'sefo_admin' 'Admin123!'
    Ok "Giris tamamlandi"

    $h = Send-Request "$FE/" $a.Jar
    if ($h.Content -match 'href="/admin"') { Ok "Admin Paneli linki GORUNUYOR" } else { Bad "Admin linki gorunmuyor" }

    $p = Send-Request "$FE/profile" $a.Jar
    if ($p.Content -match 'rolun var') { Ok "Profil 'admin rolun var' diyor" } else { Bad "Rol bilgisi yanlis" }

    $adm = Send-Request "$FE/admin" $a.Jar
    if ($adm.Status -eq 200 -and $adm.Content -notmatch 'Erisim reddedildi') { Ok "/admin aciliyor" } else { Bad "/admin acilmadi" }
    if ($adm.Content -match '200 OK')               { Ok "Admin sayfasi Backend'den 200 OK aldi" } else { Bad "Backend cagrisi basarisiz" }
    if ($adm.Content -match 'Confidential Record')  { Ok "Korumali veri ekranda" } else { Bad "Korumali veri gelmedi" }
} catch { Bad "sefo_admin akisi basarisiz: $($_.Exception.Message)" }

Write-Host "`n=== 5) Cikis (logout) ===" -ForegroundColor Cyan
try {
    $s = (Invoke-KeycloakLogin 'sefo_admin' 'Admin123!').Jar
    $before = Send-Request "$FE/" $s
    if ($before.Content -match 'Cikis Yap') { Ok "Cikis oncesi oturum acik" } else { Bad "Oturum acilmamis" }

    Send-Request "$FE/authentication/logout" $s | Out-Null
    $after = Send-Request "$FE/" $s
    if ($after.Content -match 'Giris Yap' -and $after.Content -notmatch 'Cikis Yap') {
        Ok "Cikis sonrasi oturum kapandi, 'Giris Yap' geri geldi"
    } else { Bad "Cikis sonrasi oturum hala acik gorunuyor" }

    $p = Send-Request "$FE/profile" $s
    if ($p.Uri -like "$KC/*") { Ok "Cikis sonrasi /profile yeniden giris istiyor" } else { Bad "/profile hala erisilebilir!" }
} catch { Bad "Logout akisi basarisiz: $($_.Exception.Message)" }

Write-Host ("`n{0} basarili, {1} basarisiz.`n" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
