# Keycloak IDP Authentication System — `authtake`

Merkezi Authentication & Authorization altyapisi. Kimlik dogrulama uygulamalarin
icinde degil, Keycloak IDP uzerinde yapilir.

## Bilesenler

| # | Bilesen | Teknoloji | Durum |
|---|---------|-----------|-------|
| 1 | Keycloak IDP + PostgreSQL | Docker Compose | ✅ PART 1 |
| 2 | Backend API (Resource Server) | .NET 8 Web API | ✅ PART 2 |
| 3 | Frontend (Web App) | ASP.NET Blazor (statik SSR) | ✅ PART 3 |
| 4 | 3rd Party API (Service Account) | .NET 8 Console | ✅ PART 4 |
| 5 | Token yonetimi (otomatik yenileme) | Frontend + Keycloak | ✅ PART 5 |

---

## PART 1 — Docker + Keycloak (tamamlandi)

### Dosyalar

```
docker-compose.yml                     Keycloak 26 + PostgreSQL 15, kalici volume
.env                                   Kimlik bilgileri / portlar
keycloak/import/authtake-realm.json    Realm, 3 client, 2 rol, 2 user (otomatik import)
scripts/verify-part1.ps1               12 realm/rol/akis testi
```

### Onkosul (kuruldu ✅)

| Arac | Surum | Konum |
|------|-------|-------|
| Docker Desktop | 4.85.0 / Engine 29.6.2 | `C:\Program Files\Docker\Docker` (WSL2 backend) |
| .NET SDK | 8.0.423 | `%LOCALAPPDATA%\Microsoft\dotnet` (user PATH'e eklendi) |

Yeni bir terminalde dogrula:

```powershell
docker compose version
dotnet --version
```

> `dotnet` bulunamazsa terminali kapatip yeniden ac — PATH degisikligi yalnizca
> yeni acilan sureclerde gorunur.

### Calistirma

```powershell
cd "C:\Users\user\OneDrive\Masaüstü\KeycloakAuthProject"
docker compose up -d
docker compose logs -f keycloak     # "Running the server" gorunce hazir
```

Admin Console: http://localhost:8080 → `admin` / `admin`

### Dogrulama

```powershell
.\scripts\verify-part1.ps1
```

Script sunlari kontrol eder: realm discovery endpoint, 3rd party client
credentials flow, token icindeki `aud` + `realm_access.roles`, iki test
kullanicisinin Authorization Code + PKCE ile girisi ve rol atamalari, ve
password akisinin gercekten kapali oldugu.

**Veri kalicligi dogrulandi:** `docker compose down` (volume silmeden) ve
tekrar `up` sonrasinda realm, kullanicilar ve sertlestirme ayarlari
korunuyor. Elle olusturulan bir iz kullanicisiyla test edildi.

---

## PART 2 — Backend API / Resource Server (tamamlandi)

### Dosyalar

```
src/Authtake.BackendApi/
  Auth/KeycloakAuthenticationExtensions.cs   JWT dogrulama, rol mapping, hata yanitlari
  Models/ApiModels.cs                        UserInfo / ApiResponse / ErrorResponse
  Extensions/ClaimsPrincipalExtensions.cs    Claim -> UserInfo cikarimi
  Controllers/{Public,Hello,Admin}Controller.cs
  appsettings.json                           Keycloak authority/realm/audience + CORS
scripts/verify-part2.ps1                     29 endpoint + RBAC testi
```

### Calistirma

```powershell
dotnet run --project src/Authtake.BackendApi --launch-profile http
```

API: http://localhost:5000 — Swagger UI: http://localhost:5000/swagger
(Swagger'daki **Authorize** butonuna Keycloak access token'ini yapistirip
endpoint'leri tarayicidan deneyebilirsin.)

### Endpointler

| Endpoint | Yetki | 200 | 401 | 403 |
|----------|-------|-----|-----|-----|
| `GET /api/public/hello` | Yok | herkes | — | — |
| `GET /api/hello/secure` | Gecerli token | admin + user | token yok/gecersiz/suresi dolmus | — |
| `GET /api/admin/data` | `admin` rolu | sefo_admin, 3rd party SA | token yok | sefo_user |

### Yanit Formatlari

Basarili (200) — claim'lerden cikarilmis kullanici bilgisiyle:

```json
{
  "message": "Admin data retrieved successfully.",
  "user": {
    "id": "7e5cfdf4-...", "username": "sefo_admin",
    "email": "sefo_admin@authtake.local", "name": "Sefo Admin",
    "roles": ["admin", "offline_access", "user"],
    "clientId": "authtake-frontend", "isServiceAccount": false
  },
  "data": { "endpoint": "/api/admin/data", "accessedVia": "authorization_code", "records": [...] },
  "timestamp": "2026-08-10T18:40:12.3456789+00:00"
}
```

Hata (401 / 403) — standart zarf:

```json
{
  "error": "Forbidden",
  "message": "You are authenticated but do not have the required role to access this resource.",
  "status": 403,
  "path": "/api/admin/data",
  "timestamp": "2026-08-10T18:40:12.3456789+00:00"
}
```

### Dogrulama

```powershell
.\scripts\verify-part2.ps1     # Keycloak + API ayakta olmali
```

### Tasarim Notlari

- **Rol mapping**: Keycloak rolleri `realm_access.roles` ic ice JSON'unda gelir;
  ASP.NET Core bunu tanimaz. `OnTokenValidated` icinde duz `ClaimTypes.Role`
  claim'lerine aciliyor, boylece `RequireRole("admin")` calisiyor.
- **`MapInboundClaims = false`**: JwtBearer varsayilan olarak `email`/`sub`/`name`
  claim'lerini eski SOAP sema URI'lerine cevirir. Kapatilmazsa OIDC claim adlari
  okunamaz ve `user.email` bos doner.
- **`ClockSkew = TimeSpan.Zero`**: Varsayilan 5 dk tolerans, PART 5'teki token
  expiry senaryosunu test edilemez hale getiriyordu.
- **`aud` dogrulamasi**: Sadece `authtake-backend` audience'ini tasiyan token'lar
  kabul edilir (realm'deki audience mapper'lar bunu saglar).
- **401 vs 403 ayrimi**: `OnChallenge` (kimlik yok/gecersiz) ve `OnForbidden`
  (kimlik var, rol yetersiz) olaylari ayri ayri ele alinip JSON yaziyor.

---

## PART 3 — Frontend / Blazor (tamamlandi)

### Dosyalar

```
src/Authtake.Frontend/
  Auth/KeycloakOidcExtensions.cs              OIDC (Authorization Code + PKCE), rol mapping
  Auth/HttpContextAuthenticationStateProvider.cs
  Services/BackendApiClient.cs                Backend API'ye Bearer token ile istek
  Components/Layout/MainLayout.razor          Role-based menu, giris/cikis
  Components/Pages/Home.razor                 Acilis, giris butonu
  Components/Pages/Profile.razor              Token claim'leri + cozulmus payload
  Components/Pages/AdminPanel.razor           Sadece admin
  Components/Pages/ApiTest.razor              200/401/403 canli deneme
  Components/Shared/{RedirectToLogin,AccessDenied}.razor
scripts/verify-part3.ps1                      33 uctan uca test
```

### Calistirma

Uc bilesenin de ayakta olmasi gerekiyor:

```powershell
docker compose up -d                                              # Keycloak
dotnet run --project src/Authtake.BackendApi --launch-profile http   # :5000
dotnet run --project src/Authtake.Frontend   --launch-profile http   # :5002
```

Tarayicidan http://localhost:5002 &rarr; **Giris Yap**.
`sefo_admin` / `Admin123!` ile `sefo_user` / `User123!` arasindaki farki gor.

### Sayfalar

| Adres | Kim gorebilir | Ne yapar |
|-------|---------------|----------|
| `/` | Herkes | Giris yapmamissa giris butonu, yapmissa karsilama + kartlar |
| `/profile` | Giris yapmis | Token claim'leri, roller, gecerlilik suresi, cozulmus payload |
| `/api-test` | Giris yapmis | Uc endpoint'i canli dene, 200/401/403 farkini gor |
| `/admin` | `admin` rolu | Backend'den korumali veriyi ceker |
| `/access-denied` | — | Rol yetersizliginde gelinen 403 sayfasi |

### Dogrulama

```powershell
.\scripts\verify-part3.ps1
```

Script gercek bir tarayici gibi davranir: login endpoint'ine gider, Keycloak'a
yonlendirilir, giris formunu doldurur, donen oturum cookie'siyle korumali
sayfalari ister. Iki kullaniciyla da tum akisi ve cikisi test eder.

### Tasarim Notlari ve Cozulen Sorunlar

- **Statik SSR secildi** (interaktif circuit degil): bilesenler `HttpContext`'e
  erisebildigi icin auth cookie'sindeki access token'a dogrudan ulasiliyor.
  Bunun bedeli, `AuthenticationStateProvider`'i kendimizin kaydetmesi
  (`HttpContextAuthenticationStateProvider`) &mdash; interaktif modda framework
  bunu kendisi yapar.
- **Roller access token'dan okunuyor**: Keycloak `realm_access.roles` bilgisini
  varsayilan olarak yalnizca access token'a koyar, id_token'da yoktur. OIDC
  handler kimligi id_token'dan urettigi icin roller bos kaliyordu; artik access
  token'in govdesi ayrica ayristiriliyor.
- **`AccessDeniedPath`**: Varsayilani `/Account/AccessDenied`. Bizde boyle bir
  sayfa olmadigi icin rol yetersizliginde kullanici 404 goruyordu.
- **HTTP gelistirme icin cookie ayarlari**: OIDC varsayilani, kodu siteler arasi
  bir POST ile geri gonderir (`response_mode=form_post`) ve correlation/nonce
  cookie'lerini `SameSite=None` yazar &mdash; bu da `Secure` (HTTPS) zorunlu kilar.
  HTTP'de cookie dustugu icin donuste 400 aliniyordu. `response_mode=query` +
  `SameSite=Lax` + `SecurePolicy=SameAsRequest` ile cozuldu. Uretimde HTTPS
  altinda varsayilanlara donulmelidir.
- **Iki katmanli koruma**: Menuden linki gizlemek yalnizca gorsel kolaylik.
  `/admin` adresi elle yazilsa bile once frontend 403 sayfasina duser, ayrica
  Backend API rolu bagimsiz olarak kendisi dogrular.

> **Test script'i notu:** `verify-part3.ps1` HTTP isteklerini `Invoke-WebRequest`
> yerine `HttpWebRequest` ile atar ve cookie'leri elle toplar. Iki sebep:
> (1) Windows PowerShell 5.1, yonlendirme yanitlarindaki cookie'leri oturuma
> aktarmaz; (2) .NET'in `CookieContainer`'i, yolu istek yolunun altinda olmayan
> cookie'yi reddeder ve Secure cookie'yi HTTP'de gondermez &mdash; tarayicilar
> `localhost` icin bu istisnalari tanir. Bunlar test istemcisinin sinirlari,
> uygulamanin degil.

---

## PART 4 — 3rd Party API / Service-to-Service (tamamlandi)

Kullanici etkilesimi olmadan calisan bir istemci. Tarayici, giris ekrani veya
sifre giren bir insan yoktur: uygulama kendi kimligiyle (`client_id` +
`client_secret`) Keycloak'tan token alir ve Backend API'ye o token'la gider.
Gercek hayattaki karsiligi, baska bir sirketin sisteminin bizim API'mize
baglanmasi ya da gece calisan bir entegrasyon isidir.

### Dosyalar

```
src/Authtake.ThirdPartyClient/
  Services/KeycloakTokenService.cs   Client Credentials akisi + token onbellegi
  Services/BackendApiClient.cs       Bearer token ile Backend cagrisi
  Models/TokenModels.cs              TokenResponse / TokenClaims / ApiCallResult
  Reporting/ConsoleReport.cs         Konsol ciktisi ve kontrol sayaci
  Program.cs                         5 adimlik senaryo
  appsettings.json                   Keycloak + Backend yapilandirmasi
scripts/verify-part4.ps1             19 test
```

### Calistirma

Keycloak ve Backend API ayakta olmali:

```powershell
docker compose up -d
dotnet run --project src/Authtake.BackendApi --launch-profile http
dotnet run --project src/Authtake.ThirdPartyClient
```

### Uygulamanin yaptiklari

| Adim | Ne yapar |
|------|----------|
| 1 | Keycloak'tan `grant_type=client_credentials` ile token alir, icindeki `azp` / `aud` / roller / gecerlilik suresini gosterir |
| 2 | Uc Backend endpoint'ini token ile cagirir, donen durum kodlarini yazar |
| 3 | Admin yanitini ayristirir: `isServiceAccount`, `accessedVia` alanlarini dogrular |
| 4 | Negatif kontrol: token gondermeden ayni adrese gider, 401 bekler |
| 5 | Token onbellegini gosterir: ikinci istek Keycloak'a gitmez |

Uygulama kendi kontrollerini sayar ve **cikis kodu** dondurur (0 = hepsi gecti),
boylece otomatik testlerden veya bir CI adimindan calistirilabilir.

### Frontend ile farki

| | Frontend (PART 3) | 3rd Party (PART 4) |
|---|---|---|
| Akis | Authorization Code + PKCE | Client Credentials |
| Kullanici | Var, sifresini Keycloak'a girer | **Yok** |
| Kimlik | Gercek kisi (`sefo_admin`) | Service account (`service-account-authtake-3rdparty`) |
| Client tipi | Public (secret saklayamaz) | Confidential (`client_secret` sunucuda) |
| Refresh token | Var | Yok — token dolunca ayni sekilde yenisi istenir |
| Backend'in gordugu | `accessedVia: authorization_code` | `accessedVia: client_credentials` |

Dikkat: Backend API tarafinda **hicbir degisiklik yapilmadi**. Ayni endpoint,
ayni rol kontrolu, ayni `Authorization: Bearer` basligi. Backend'i istegin bir
insandan mi yoksa bir servisten mi geldigi ilgilendirmiyor — yalnizca token'in
gecerli olup olmadigi ve icindeki roller. Merkezi kimlik dogrulamanin en somut
faydasi bu.

### Dogrulama

```powershell
.\scripts\verify-part4.ps1
```

Script uygulamayi calistirip cikis kodunu ve ciktisini kontrol eder, ardindan
iki bagimsiz test yapar: **yanlis `client_secret`** ile uygulamanin temiz bir
hatayla durdugunu (ortam degiskeni ile ezerek), ve uygulamadan bagimsiz olarak
akisin kendisinin de calistigini.

### Tasarim Notlari

- **Token onbellegi**: Her istek icin yeni token almak gereksiz. Token, suresi
  dolmadan 30 saniye oncesine kadar yeniden kullanilir; bu pay, istek yoldayken
  token'in gecersizlesmesini onler.
- **`ContentRootPath = AppContext.BaseDirectory`**: `Host.CreateApplicationBuilder`
  yapilandirmayi varsayilan olarak **calisma dizininde** arar. `dotnet run
  --project ...` cozum kokunden calistirildiginda `appsettings.json` bulunamaz;
  icerik koku uygulamanin kendi klasorune sabitlendi.
- **`aud` claim'i tek metin de olabilir, dizi de**: JWT standardi ikisine de izin
  verir, ayristirici iki durumu da karsilar.
- **Cikis kodu**: Uygulama basarisiz kontrol varsa 1 doner. Bir demo programini
  test edilebilir hale getiren en ucuz yontem.

---

## PART 5 — Token Yonetimi / Otomatik Yenileme (tamamlandi)

Access token 15 dakika yasar. PART 5'ten once bunun sonucu su idi: 15 dakika
sonra kullanici arayuzde hala "giris yapmis" gorunuyor (oturum cookie'si 7 gun
gecerli) ama Backend cagrilari **401 donmeye basliyordu.**

Artik uygulama, token'in omru dolmadan **1 dakika once** refresh token ile
sessizce yenisini aliyor. Kullanici bunu hic fark etmiyor.

### Dosyalar

```
src/Authtake.Frontend/
  Auth/TokenRefreshService.cs        Yenileme cagrisi + paralel istek koordinasyonu
  Auth/KeycloakOidcExtensions.cs     OnValidatePrincipal icinde yenileme tetigi
scripts/verify-part5.ps1             16 test
```

### Nasil calisiyor

Yenileme, cookie her dogrulandiginda (yani her istekte) kontrol edilir:

```
Istek gelir
   -> Cookie cozulur, icindeki 'expires_at' okunur
   -> Suresi dolmaya 1 dk'dan az mi kaldi?
        Hayir -> devam
        Evet  -> refresh token ile Keycloak'tan yeni token al
                   Basarili -> yeni token'lari cookie'ye yaz, devam
                   Basarisiz -> oturumu kapat, giris ekranina gonder
```

Bu, `CookieAuthenticationEvents.OnValidatePrincipal` uzerine kurulu; ayri bir
zamanlayici ya da arka plan isi yok. Yenilenen token'lar `StoreTokens` ile
cookie'ye yazilir ve `ShouldRenew = true` ile cookie yeniden gonderilir.

### Paralel istek sorunu ve cozumu

Realm'de refresh token rotasyonu acik: her yenilemede yeni bir refresh token
verilir ve **eskisi aninda gecersizlesir.** Bir sayfa ayni anda birkac istek
atarsa hepsi ellerindeki ayni eski refresh token ile yenilemeye kalkar; ilki
basarili olur, digerleri reddedilir ve kullanici bosuna disari atilir.

Iki onlem birlikte kullaniliyor:

| Onlem | Ne yapar |
|-------|----------|
| Kullanici basina kilit (`SemaphoreSlim`) | Ayni anda yalnizca bir yenileme calisir |
| 30 saniyelik onbellek | Yarisi kaybeden istek, kazananin aldigi token'lari onbellekten okur; tekrar denemez |

Onbellek anahtari **eski** refresh token'dir: ayni eski token'la gelen her istek
ayni yeni token setine ulasir.

### Dogrulama

```powershell
.\scripts\verify-part5.ps1
```

Test 15 dakika beklemek yerine realm'in `accessTokenLifespan` degerini admin API
ile **gecici olarak 40 saniyeye** dusurur, token'in gercekten eskimesini bekler,
sonra ayari geri alir. Dogruladiklari:

| Kontrol | Beklenen |
|---------|----------|
| Bekleme sonrasi profil sayfasi | Gecerlilik sonu ILERI tasinmis |
| Kullanici durumu | Hala giris yapmis (disari atilmamis) |
| `/api/hello/secure` ve `/api/admin/data` | 200 OK &mdash; yenilenen token Backend'de gecerli |
| Keycloak'ta oturum sonlandirilirsa | Yenileme reddedilir, kullanici giris ekranina yonlendirilir |
| Test sonrasi realm | `accessTokenLifespan` eski degerine doner |

Son madde onemli: ayar geri alinmazsa hem uygulama hem diger testler
kisaltilmis token omruyle calismaya devam ederdi. Temizlik `finally` blogunda
ve admin token'i orada **tazeleniyor** &mdash; master realm'de admin token'inin
varsayilan omru 60 saniye, test ise iki kez ~50 saniye bekliyor.

---

## Guvenlik

### Dogrulanmis korumalar

`scripts/verify-security.ps1` (19 test) su saldiri senaryolarini calistirir ve
hepsinin reddedildigini dogrular:

| Senaryo | Beklenen |
|---------|----------|
| Imzasi bozulmus token | 401 |
| Rolleri degistirilmis token (`admin`, `superuser`, `root` eklenmis) | 401 |
| `alg=none` &mdash; "imza kontrolu yapma" saldirisi | 401 |
| Baska realm'den alinmis, kendi icinde gecerli token | 401 |
| `id_token`'i access token yerine kullanmak | 401 |
| Rolu yetersiz kullanici | 403 (401 degil) |
| Public client'ta password akisi | reddedilir |
| Public client'ta client_credentials | reddedilir |
| Eski refresh token'i ikinci kez kullanmak | reddedilir (rotasyon) |
| Ard arda yanlis sifre | hesap gecici kilitlenir |

Test, kilitledigi hesabi sonunda admin API ile tekrar acar; aksi halde diger
script'ler 15 dakika calisamazdi.

### Sertlestirme kararlari

| Karar | Gerekce |
|-------|---------|
| Public client'ta **password (Direct Access Grants) akisi kapali** | Acik kalirsa PKCE'nin sagladigi korumayi atlayan bir yan kapi olusur. Testler de artik gercek Authorization Code + PKCE akisini kullanir (`scripts/lib/AuthFlow.ps1`) |
| **Brute force korumasi acik** | `failureFactor=5`, kademeli bekleme, en fazla 15 dk kilit. Password akisiyla birlikte kapali olmasi ciddi bir riskti |
| **Refresh token rotasyonu** (`revokeRefreshToken=true`) | Her yenilemede eski token gecersizlesir; calinan bir refresh token'in omru tek kullanimla sinirlanir |
| Servis hesabina **`admin` yerine `service-api` rolu** | En az yetki ilkesi: `admin` rolune ileride eklenecek yetkiler 3rd party servise otomatik olarak gecmez. Insan ve makine yetkileri ayri kalir |
| PostgreSQL portu **disariya acilmadi** | Veritabanina yalnizca Keycloak konteyneri erisir |

### Bilinen davranis: cikis, access token'i iptal etmez

Cikis yapildiginda refresh token gercekten iptal edilir, ancak elde bulunan
access token **suresi dolana kadar (en fazla 15 dk) gecerli kalmaya devam eder.**

Bu bir acik degil, JWT'nin dogasidir: Backend her istekte Keycloak'a "bu token
hala gecerli mi" diye sormaz, imzaya ve `exp` alanina bakar. Aninda iptal
gerekiyorsa token introspection (her istekte IDP'ye sorma) gerekir &mdash; bunun
bedeli her cagrida ek bir ag turudur. Kisa omur bu riski sinirlar.

Davranis sessizce degisirse fark edelim diye bu da teste baglandi.

### Bulunan ve kapatilan acik: acik yonlendirme (open redirect)

Giris endpoint'i, giris sonrasi donulecek adresi kullanicidan aliyordu
(`/authentication/login?returnUrl=...`). Kontrol yalnizca "goreli adres mi"
diye bakiyordu:

```csharp
Uri.IsWellFormedUriString(returnUrl, UriKind.Relative)   // yetersiz
```

`//kotusite.example` RFC 3986'ya gore **gecerli bir goreli adrestir**
(network-path reference), ama tarayici onu `http://kotusite.example` olarak
yorumlar. Test edildi ve dogrulandi: kullanici gercek Keycloak sayfasinda giris
yaptiktan sonra baska bir siteye dusuruluyordu.

Sömürü senaryosu: saldirgan kurbanina `.../authentication/login?returnUrl=//saldirgan.example`
linkini gonderir. Kurban **gercek** giris ekranini gorur, dogru sifresini girer,
ve saldirganin sayfasinda son bulur; orada "oturumunuz dustu, tekrar girin"
diyen sahte bir ekran sifre toplayabilir. Acik yonlendirmenin klasik kullanimi
budur: kimlik avini gercek akisin guvenilirligiyle guclendirmek.

Cozum, ASP.NET Core'un kendi `Url.IsLocalUrl` mantigi: adres tek bir `/` ile
baslamali ve ardindan `/` veya `\` gelmemeli. `verify-part3.ps1` bes varyanti
(mutlak adres, `//`, `/\`, `\\`, bosluklu) kalici olarak test eder.

### Redirect URI'lar daraltildi

`authtake-frontend` icin kayitli adresler joker karakterliydi
(`http://localhost:5002/*`) ve kullanilmayan girdiler iceriyordu (React icin
`:3000`, `:5001`). Joker redirect URI, ayni origin'de bir acik yonlendirme
bulunmasi halinde yetki kodunun calinmasina zemin hazirlar &mdash; yukaridaki
acik tam da bu origin'deydi.

| | Once | Sonra |
|---|---|---|
| redirectUris | 4 adet, joker karakterli | `http://localhost:5002/signin-oidc` |
| webOrigins | 4 adet | `http://localhost:5002` |
| post logout | 4 adet, joker karakterli | `http://localhost:5002/signout-callback-oidc` |

Daraltirken bir hata yapildi ve testler yakaladi: post-logout adresi olarak
`http://localhost:5002/` kaydedilmisti, oysa OIDC handler cikista
**`SignedOutCallbackPath`** degerini gonderiyor. Keycloak adresi tanimayinca
400 donuyor, Keycloak oturumu kapanmiyor ve kullanici bir sonraki istekte
sessizce yeniden iceri aliniyordu. Dogru adres kaydedildi.

### Bilinen, kapatilmayan: cikis GET ile yapiliyor

`/authentication/logout` bir GET endpoint'idir; saldirganin sayfasindaki bir
`<img src="...">` etiketi kullaniciyi oturumdan dusurebilir (CSRF). Etkisi
yalnizca rahatsizlik verir &mdash; veri sizmaz, kullanici tekrar giris yapabilir.
OIDC'nin RP-initiated logout akisi da zaten tarayici yonlendirmesi uzerine
kuruludur. Uretimde POST + antiforgery token tercih edilmelidir.

### Bilinerek yapilan demo tercihi: profil sayfasi ham token'i gosteriyor

`/profile` sayfasi access token'in kendisini ve cozulmus govdesini ekrana basar.
Bu, projenin ogretici amaci icin bilincli bir tercihtir &mdash; token'in ne
oldugunu gormek konuyu anlamanin en hizli yolu.

Gercek bir uygulamada yapilmamalidir: oturum cookie'si `HttpOnly` isaretlidir,
yani JavaScript'in token'a erismesini engelleriz. Token'i HTML'e basmak bu
korumayi anlamsiz kilar &mdash; sayfada bir XSS acigi olsa token dogrudan
okunabilirdi. Uretimde bu kart kaldirilmalidir.

### Beklenmeyen hatalar ve IDP erisilemezligi

- **500 yanitlari** da 401/403 ile ayni hata zarfini kullanir
  (`error` / `message` / `status` / `path` / `timestamp`). Ic detay
  sizdirilmez; ayrinti yalnizca loglara yazilir.
- **Keycloak erisilemezse** Backend API imza anahtarlarini alamaz ve korumali
  endpoint'ler **401** doner &mdash; yani sistem acik kalmaz, kapanir
  (fail-closed). Dogrulanmis davranistir.

> Not: 500 zarfi kod icinde yerinde, ancak otomatik testlerde dogrulanmiyor.
> Gercek bir 500 tetiklemek icin uygulamaya kalici bir "hata uret" endpoint'i
> eklemek gerekirdi; bu, uretim koduna test amacli bir acik eklemek anlamina
> geldigi icin tercih edilmedi.

### Uretime alirken yapilmasi gerekenler

Asagidakiler **bilerek** gelistirme ayarinda birakildi. Yerel calistirmayi
kolaylastirirlar; uretimde kabul edilemezler.

| # | Konu | Su anki durum | Uretimde |
|---|------|---------------|----------|
| 1 | **TLS** | Her sey HTTP: `sslRequired: none`, `RequireHttpsMetadata: false`, cookie'ler `SameAsRequest` | HTTPS zorunlu; `sslRequired: external`, cookie'ler `Always`, OIDC varsayilanlarina (form_post + SameSite=None) donulur |
| 2 | **Gizli bilgiler** | Client secret'lar, `admin`/`admin` ve test sifreleri repoda acikta | Secret yoneticisi (Vault, Key Vault, Docker secrets); realm import'tan cikarilir |
| 3 | **Keycloak modu** | `start-dev`, bellek ici cache, admin konsolu varsayilan sifreyle | `start` + uretim veritabani + guclu admin sifresi + admin konsoluna ag kisitlamasi |
| 4 | **Rate limiting** | Backend API'de yok | Reverse proxy veya `AddRateLimiter` ile istek sinirlama |
| 5 | **Token omru** | Access 15 dk, SSO oturumu 7 gun | Ihtiyaca gore kisaltilir; 7 gun cogu senaryo icin uzun |

---

## Realm Yapilandirmasi

**Realm:** `authtake` — Access token 15 dk (900s), SSO session 7 gun (604800s)

### Clients

| Client ID | Tip | Flow | Secret |
|-----------|-----|------|--------|
| `authtake-frontend` | Public | Authorization Code + PKCE (S256) | — |
| `authtake-backend` | Confidential | Yok — sadece JWT dogrular | `backend-secret-change-me-2024` |
| `authtake-3rdparty` | Confidential | Client Credentials (service account) | `thirdparty-secret-change-me-2024` |

`authtake-frontend` redirect URI'lari hem React (`:3000`) hem .NET
(`:5001` / `:5002`) icin onceden tanimli — PART 3'te frontend secimi
degistiginde realm'i tekrar duzenlemeye gerek yok.

`authtake-frontend` ve `authtake-3rdparty` uzerinde **audience mapper** var:
uretilen access token'larin `aud` claim'i `authtake-backend` icerir, boylece
Backend API audience dogrulamasi yapabilir.

`authtake-backend` icin tum flow'lar kapali (standard/implicit/direct/service
account) — bu, Keycloak 26'da "bearer-only" resource server'in karsiligidir.

### Roller & Kullanicilar

| Kullanici | Sifre | Roller |
|-----------|-------|--------|
| `sefo_admin` | `Admin123!` | `admin`, `user` |
| `sefo_user` | `User123!` | `user` |
| `service-account-authtake-3rdparty` | — (client secret) | `service-api` |

---

## Manuel Test — Client Credentials Flow

```powershell
$r = Invoke-RestMethod -Method Post `
  -Uri "http://localhost:8080/realms/authtake/protocol/openid-connect/token" `
  -ContentType 'application/x-www-form-urlencoded' `
  -Body @{
    grant_type    = 'client_credentials'
    client_id     = 'authtake-3rdparty'
    client_secret = 'thirdparty-secret-change-me-2024'
  }
$r.access_token
```

Token'i jwt.io'ya yapistirarak `realm_access.roles` ve `aud` claim'lerini gorebilirsin.

---

## Notlar

- Veriler `postgres_data` ve `keycloak_data` named volume'larinda kalicidir.
  `docker compose down` veriyi silmez; `docker compose down -v` siler.
- Realm import **sadece realm yoksa** calisir. Realm JSON'i degistirip yeniden
  yuklemek icin: `docker compose down -v; docker compose up -d`
- Realm JSON'da gecersiz bir alan varsa Keycloak **acilista crash eder ama
  container `running` gorunur** (restart loop). `docker compose ps` yaniltici
  olabilir; sorun cikarsa `docker compose logs keycloak | Select-String ERROR`.
  Keycloak 26 su alanlari kabul etmez: client `postLogoutRedirectUris`
  (yerine `attributes["post.logout.redirect.uris"]`), realm `defaultRoles`.
- `start-dev` modu ve `sslRequired: none` yalnizca gelistirme icindir.
  Production'da `start` + HTTPS + gercek secret'lar kullanilmalidir.
