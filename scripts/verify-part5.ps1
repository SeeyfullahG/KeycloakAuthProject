# PART 5 dogrulama scripti - otomatik token yenileme
# Onkosul: Keycloak, Backend API :5000, Frontend :5002
# Kullanim: .\scripts\verify-part5.ps1
#
# Access token normalde 15 dakika yasar; testin 15 dakika beklemesi anlamsiz.
# Bu yuzden realm'in token omrunu admin API ile GECICI olarak kisaltiyoruz,
# yenilemenin gercekten calistigini kanitliyoruz ve ayari geri aliyoruz.
# Ayar geri alinmazsa diger testler ve uygulama etkilenirdi.

. "$PSScriptRoot\lib\AuthFlow.ps1"

$FE    = 'http://localhost:5002'
$KC    = 'http://localhost:8080'
$REALM = 'authtake'
$SHORT_LIFESPAN = 40   # saniye

$script:Pass = 0
$script:Fail = 0
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green; $script:Pass++ }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:Fail++ }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }

function Get-AdminToken {
    (Invoke-RestMethod -Method Post -Uri "$KC/realms/master/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; client_id = 'admin-cli'
                 username = 'admin'; password = 'admin' }).access_token
}

function Set-AccessTokenLifespan($adminToken, [int] $seconds) {
    # Yalnizca degistirmek istedigimiz alani gonderiyoruz; Keycloak kismi
    # guncellemeyi kabul eder (204). Tum realm temsilini geri gondermek
    # gereksiz oldugu gibi serilestirme sirasinda bozulmaya da acik.
    Invoke-RestMethod -Method Put -Uri "$KC/admin/realms/$REALM" `
        -Headers @{ Authorization = "Bearer $adminToken" } `
        -ContentType 'application/json' `
        -Body (@{ accessTokenLifespan = $seconds } | ConvertTo-Json) | Out-Null
}

# Frontend'e giris yapip oturum cookie'sini dondurur.
function Connect-Frontend($username, $password) {
    $jar = New-Jar
    $login = Send-Request "$FE/authentication/login" $jar
    if ($login.Content -notmatch 'action="([^"]+)"') { throw "Keycloak giris formu bulunamadi" }
    $action = [System.Net.WebUtility]::HtmlDecode($matches[1])

    $form = 'username={0}&password={1}&credentialId=' -f
        [Uri]::EscapeDataString($username), [Uri]::EscapeDataString($password)
    $post = Send-Request $action $jar 'POST' $form
    if ($post.Uri -notlike "$FE/*") { throw "Uygulamaya donulemedi: $($post.Uri)" }
    return $jar
}

# Profil sayfasindaki "gecerlilik sonu" satirindan tarihi cikarir.
function Get-TokenExpiry($jar) {
    $page = Send-Request "$FE/profile" $jar
    if ($page.Content -match '(?s)Access token gecerlilik sonu.*?<td>\s*<span>([^<]+)</span>') {
        return $matches[1].Trim()
    }
    return $null
}

Write-Host "`n=== 0) Servisler ===" -ForegroundColor Cyan
foreach ($svc in @(
    @{ n = 'Keycloak';    u = "$KC/realms/$REALM/.well-known/openid-configuration" },
    @{ n = 'Backend API'; u = 'http://localhost:5000/api/public/hello' },
    @{ n = 'Frontend';    u = "$FE/" })) {
    $r = Send-Request $svc.u (New-Jar)
    if ($r.Status -eq 200) { Ok "$($svc.n) yanit veriyor" } else { Bad "$($svc.n): $($r.Status)" }
}
if ($script:Fail) { Write-Host "`nServisleri baslat ve tekrar dene.`n" -ForegroundColor Yellow; exit 1 }

$adminToken = $null
$originalLifespan = $null
try {
    $adminToken = Get-AdminToken
    $originalLifespan = (Invoke-RestMethod -Uri "$KC/admin/realms/$REALM" `
        -Headers @{ Authorization = "Bearer $adminToken" }).accessTokenLifespan
    Ok "Admin API erisimi var (mevcut accessTokenLifespan=$originalLifespan sn)"

    Write-Host "`n=== 1) Token omru gecici olarak kisaltiliyor ===" -ForegroundColor Cyan
    Set-AccessTokenLifespan $adminToken $SHORT_LIFESPAN
    $applied = (Invoke-RestMethod -Uri "$KC/admin/realms/$REALM" `
        -Headers @{ Authorization = "Bearer $adminToken" }).accessTokenLifespan
    if ($applied -eq $SHORT_LIFESPAN) { Ok "accessTokenLifespan = $SHORT_LIFESPAN sn" }
    else { Bad "Ayar uygulanmadi (gelen: $applied)" }

    Write-Host "`n=== 2) Giris yapiliyor ===" -ForegroundColor Cyan
    $jar = Connect-Frontend 'sefo_admin' 'Admin123!'
    Ok "Oturum acildi"

    $firstExpiry = Get-TokenExpiry $jar
    if ($firstExpiry) { Ok "Ilk access token gecerlilik sonu: $firstExpiry" }
    else { Bad "Profil sayfasindan gecerlilik suresi okunamadi" }

    $api = Send-Request "$FE/api-test?call=secure" $jar
    if ($api.Content -match '200 OK') { Ok "Backend cagrisi 200 OK (yenileme oncesi)" }
    else { Bad "Ilk backend cagrisi basarisiz" }

    Write-Host "`n=== 3) Token'in dolmasi bekleniyor ===" -ForegroundColor Cyan
    # Yenileme, dolmadan 1 dk once devreye giriyor. Omur 40 sn oldugu icin
    # uygulama pratikte her istekte yeniliyor; yine de token'in gercekten
    # eskimesi icin bekliyoruz.
    Note "$($SHORT_LIFESPAN + 10) saniye bekleniyor..."
    Start-Sleep -Seconds ($SHORT_LIFESPAN + 10)

    Write-Host "`n=== 4) Yenileme calisti mi? ===" -ForegroundColor Cyan
    $secondExpiry = Get-TokenExpiry $jar
    if ($secondExpiry) { Ok "Yeni access token gecerlilik sonu: $secondExpiry" }
    else { Bad "Bekleme sonrasi profil okunamadi - oturum dusmus olabilir" }

    if ($firstExpiry -and $secondExpiry -and $firstExpiry -ne $secondExpiry) {
        Ok "Gecerlilik suresi ILERI tasindi - token sessizce yenilendi"
    } else {
        Bad "Gecerlilik suresi degismedi ($firstExpiry -> $secondExpiry)"
    }

    $landing = Send-Request "$FE/" $jar
    if ($landing.Content -match 'Hos geldin') { Ok "Kullanici hala giris yapmis durumda" }
    else { Bad "Kullanici disari atilmis - yenileme calismadi" }

    Write-Host "`n=== 5) Yenilenen token Backend'de gecerli mi? ===" -ForegroundColor Cyan
    # Asil kanit bu: eski token dolmus olmali, yine de 200 aliyoruz.
    $api2 = Send-Request "$FE/api-test?call=secure" $jar
    if ($api2.Content -match '200 OK') { Ok "/api/hello/secure -> 200 OK (yenilenmis token ile)" }
    else { Bad "Backend cagrisi basarisiz - yenilenen token calismiyor" }

    $api3 = Send-Request "$FE/api-test?call=admin" $jar
    if ($api3.Content -match '200 OK') { Ok "/api/admin/data -> 200 OK (roller korundu)" }
    else { Bad "Admin cagrisi basarisiz" }

    Write-Host "`n=== 6) Oturum Keycloak'ta sonlandirilirsa ===" -ForegroundColor Cyan
    # Refresh token de gecersizlesirse kullanici yeniden giris yapmali.
    $adminToken = Get-AdminToken   # ilk token bu noktada dolmus olabilir
    $userId = (Invoke-RestMethod -Uri "$KC/admin/realms/$REALM/users?username=sefo_admin&exact=true" `
        -Headers @{ Authorization = "Bearer $adminToken" })[0].id
    Invoke-RestMethod -Method Post -Uri "$KC/admin/realms/$REALM/users/$userId/logout" `
        -Headers @{ Authorization = "Bearer $adminToken" } | Out-Null
    Ok "Kullanicinin Keycloak oturumlari admin API ile sonlandirildi"

    Note "Token'in dolmasi bekleniyor ki yenileme denensin..."
    Start-Sleep -Seconds ($SHORT_LIFESPAN + 10)

    $afterLogout = Send-Request "$FE/profile" $jar
    if ($afterLogout.Uri -like "$KC/*") {
        Ok "Yenileme reddedildi ve kullanici giris ekranina yonlendirildi"
    } else {
        Bad "Oturum hala acik gorunuyor: $($afterLogout.Uri)"
    }
} catch {
    Bad "Test calistirilamadi: $($_.Exception.Message)"
} finally {
    if ($originalLifespan) {
        try {
            # Admin token'i tazeliyoruz: master realm'de varsayilan omru 60 sn,
            # bu test ise iki kez ~50 sn bekliyor. Eski token'la temizlik 401 alir
            # ve realm kisaltilmis omurle kalirdi.
            $adminToken = Get-AdminToken
            Set-AccessTokenLifespan $adminToken $originalLifespan
            $restored = (Invoke-RestMethod -Uri "$KC/admin/realms/$REALM" `
                -Headers @{ Authorization = "Bearer $adminToken" }).accessTokenLifespan
            if ($restored -eq $originalLifespan) { Ok "Token omru geri alindi ($restored sn)" }
            else { Bad "Token omru geri alinamadi! Su an: $restored" }
        } catch {
            Bad "Token omru geri alinamadi! Realm'i elle duzelt: $($_.Exception.Message)"
        }
    }
}

Write-Host ("`n{0} basarili, {1} basarisiz.`n" -f $script:Pass, $script:Fail) `
    -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
