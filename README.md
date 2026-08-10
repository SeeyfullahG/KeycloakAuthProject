# Keycloak IDP Authentication System — `authtake`

Merkezi Authentication & Authorization altyapisi. Kimlik dogrulama uygulamalarin
icinde degil, Keycloak IDP uzerinde yapilir.

## Bilesenler

| # | Bilesen | Teknoloji | Durum |
|---|---------|-----------|-------|
| 1 | Keycloak IDP + PostgreSQL | Docker Compose | ✅ PART 1 |
| 2 | Backend API (Resource Server) | .NET 8 Web API | ✅ PART 2 |
| 3 | Frontend (Web App) | ASP.NET Blazor Server | ⏳ PART 3 |
| 4 | 3rd Party API (Service Account) | .NET Console | ⏳ PART 4 |

---

## PART 1 — Docker + Keycloak (tamamlandi)

### Dosyalar

```
docker-compose.yml                     Keycloak 26 + PostgreSQL 15, kalici volume
.env                                   Kimlik bilgileri / portlar
keycloak/import/authtake-realm.json    Realm, 3 client, 2 rol, 2 user (otomatik import)
scripts/verify-part1.ps1               Dogrulama scripti
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
credentials flow, token icindeki `aud` + `realm_access.roles`, ve iki test
kullanicisinin login + rol atamalari.

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
scripts/verify-part2.ps1                     27 endpoint + RBAC testi
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

## Realm Yapilandirmasi

**Realm:** `authtake` — Access token 15 dk (900s), SSO session 7 gun (604800s)

### Clients

| Client ID | Tip | Flow | Secret |
|-----------|-----|------|--------|
| `authtake-frontend` | Public | Authorization Code + PKCE (S256), Password (test) | — |
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
| `service-account-authtake-3rdparty` | — (client secret) | `admin`, `user` |

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
