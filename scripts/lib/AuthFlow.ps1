# Ortak kimlik dogrulama yardimcilari (test script'leri icin)
# Dot-source ile yuklenir:  . "$PSScriptRoot\lib\AuthFlow.ps1"
#
# NEDEN BU DOSYA VAR
# Testler eskiden kullanici token'ini "password" (Direct Access Grants) akisiyla
# aliyordu. Bu akis public client'ta acik birakilinca PKCE'nin sagladigi korumayi
# atlayan bir yan kapi olusturuyordu, bu yuzden kapatildi. Artik testler de
# gercek tarayicinin yaptigini yapiyor: Authorization Code + PKCE.
#
# ISTEMCI SINIRLARI (uygulamanin degil, .NET'in)
#  1. Windows PowerShell 5.1'in Invoke-WebRequest'i yonlendirme (3xx)
#     yanitlarindaki cookie'leri oturuma aktarmaz.
#  2. .NET'in CookieContainer'i, yolu istek yolunun altinda olmayan cookie'yi
#     reddeder ve Secure cookie'yi HTTP uzerinden hic gondermez. Tarayicilar
#     http://localhost'u "guvenilir kaynak" saydigi icin bu sorunu yasamaz.
# Bu yuzden HttpWebRequest kullanip cookie'leri elle topluyoruz.

function New-Jar { New-Object System.Net.CookieContainer }

function Clear-SecureFlag($jar) {
    foreach ($u in @("https://localhost:8080/realms/authtake/",
                     "https://localhost:8080/",
                     "https://localhost:5002/",
                     "https://localhost:5002/signin-oidc")) {
        foreach ($c in $jar.GetCookies([Uri]$u)) { $c.Secure = $false }
    }
}

function Add-ResponseCookies($jar, $resp) {
    $raw = $resp.Headers['Set-Cookie']
    if ([string]::IsNullOrEmpty($raw)) { return }

    # Birden fazla Set-Cookie tek baslikta virgulle birlesmis olabilir. Virgulu
    # yalnizca ardindan "isim=" gelen yerde bolerek Expires icindeki
    # "Fri, 14 Aug ..." virgulunu korumus oluyoruz.
    foreach ($piece in [regex]::Split($raw, ',(?=[^;,]+=)')) {
        $parts = $piece.Split(';')
        $nv = $parts[0].Trim()
        $eq = $nv.IndexOf('=')
        if ($eq -lt 1) { continue }

        $path = '/'
        foreach ($attr in $parts | Select-Object -Skip 1) {
            $a = $attr.Trim()
            if ($a -like 'path=*') { $path = $a.Substring(5) }
        }

        $cookie = New-Object System.Net.Cookie(
            $nv.Substring(0, $eq).Trim(), $nv.Substring($eq + 1).Trim(), $path, 'localhost')
        try { $jar.Add($cookie) } catch { }
    }
}

# Yonlendirmeleri elle takip eder ki her adimda cookie toplanabilsin.
# -StopAtRedirect: ilk yonlendirmede durur ve Location basligini dondurur.
# Authorization Code akisinda buna ihtiyac var: donen kod TEK KULLANIMLIKTIR,
# yonlendirmeyi takip edersek kodu frontend tuketir ve bizim takasimiz basarisiz olur.
function Send-Request($uri, $jar, $method = 'GET', $body = $null, [switch]$StopAtRedirect) {
    $current = $uri
    $verb = $method
    $payload = $body

    for ($hop = 0; $hop -lt 12; $hop++) {
        Clear-SecureFlag $jar

        $req = [System.Net.HttpWebRequest]::Create($current)
        $req.CookieContainer = $jar
        $req.AllowAutoRedirect = $false
        $req.Method = $verb
        $req.UserAgent = 'authtake-verify'
        $req.Timeout = 20000

        if ($null -ne $payload) {
            $req.ContentType = 'application/x-www-form-urlencoded'
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $req.ContentLength = $bytes.Length
            $stream = $req.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()
        }

        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if (-not $resp) { throw }
        }

        Add-ResponseCookies $jar $resp
        $status = [int]$resp.StatusCode
        $location = $resp.Headers['Location']

        if ($status -in 301, 302, 303, 307, 308 -and $location) {
            $absolute = (New-Object Uri([Uri]$current, $location)).AbsoluteUri
            $resp.Close()

            if ($StopAtRedirect) {
                return @{ Status = $status; Content = ''; Uri = $current; Location = $absolute }
            }

            $current = $absolute
            $verb = 'GET'      # 302/303 sonrasi istek GET'e doner
            $payload = $null
            continue
        }

        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        $content = $reader.ReadToEnd()
        $reader.Close()
        $resp.Close()

        return @{ Status = $status; Content = $content; Uri = $current; Location = $null }
    }

    throw "Cok fazla yonlendirme: $uri"
}

function ConvertTo-Base64Url([byte[]]$bytes) {
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# PKCE: rastgele bir gizli deger (verifier) uretir ve onun SHA-256 ozetini
# (challenge) dondurur. Ozet Keycloak'a basta gonderilir, gizli degerin kendisi
# ise ancak kodu token'a cevirirken. Kodu calan biri gizli degeri bilmedigi icin
# token alamaz.
function New-PkcePair {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $verifier = ConvertTo-Base64Url $bytes

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $challenge = ConvertTo-Base64Url $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))

    return @{ Verifier = $verifier; Challenge = $challenge }
}

<#
.SYNOPSIS
Gercek tarayici akisiyla (Authorization Code + PKCE) kullanici access token'i alir.

.DESCRIPTION
Adimlar:
  1. PKCE ciftini uret, /auth adresine git  -> Keycloak giris formu doner
  2. Formu kullanici adi/sifre ile gonder   -> Keycloak ?code=... ile yonlendirir
  3. Yonlendirmeyi TAKIP ETME, kodu al
  4. Kodu + code_verifier ile /token adresine git -> access token
#>
function Get-UserToken {
    param(
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password,
        [string] $Keycloak = 'http://localhost:8080',
        [string] $Realm = 'authtake',
        [string] $ClientId = 'authtake-frontend',
        [string] $RedirectUri = 'http://localhost:5002/signin-oidc'
    )

    $base = "$Keycloak/realms/$Realm/protocol/openid-connect"
    $jar = New-Jar
    $pkce = New-PkcePair
    $state = [Guid]::NewGuid().ToString('N')

    $authUrl = "$base/auth?" + (@(
        "client_id=$([Uri]::EscapeDataString($ClientId))"
        "redirect_uri=$([Uri]::EscapeDataString($RedirectUri))"
        "response_type=code"
        "scope=$([Uri]::EscapeDataString('openid profile email'))"
        "state=$state"
        "code_challenge=$($pkce.Challenge)"
        "code_challenge_method=S256"
    ) -join '&')

    $loginPage = Send-Request $authUrl $jar
    if ($loginPage.Content -notmatch 'action="([^"]+)"') {
        throw "Keycloak giris formu bulunamadi (status $($loginPage.Status))"
    }
    $action = [System.Net.WebUtility]::HtmlDecode($matches[1])

    $form = 'username={0}&password={1}&credentialId=' -f
        [Uri]::EscapeDataString($Username), [Uri]::EscapeDataString($Password)
    $submit = Send-Request $action $jar 'POST' $form -StopAtRedirect

    if (-not $submit.Location) { throw "Giris basarisiz: yonlendirme gelmedi ($Username)" }
    if ($submit.Location -notmatch '[?&]code=([^&]+)') {
        throw "Yanitta yetki kodu yok: $($submit.Location)"
    }
    $code = [Uri]::UnescapeDataString($matches[1])

    $tokenBody = @(
        "grant_type=authorization_code"
        "code=$([Uri]::EscapeDataString($code))"
        "redirect_uri=$([Uri]::EscapeDataString($RedirectUri))"
        "client_id=$([Uri]::EscapeDataString($ClientId))"
        "code_verifier=$($pkce.Verifier)"
    ) -join '&'

    $tokenResponse = Invoke-RestMethod -Method Post -Uri "$base/token" `
        -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody -TimeoutSec 20

    return $tokenResponse
}

<#
.SYNOPSIS
Client Credentials akisiyla servis hesabi token'i alir (kullanici yok).
#>
function Get-ServiceToken {
    param(
        [string] $Keycloak = 'http://localhost:8080',
        [string] $Realm = 'authtake',
        [string] $ClientId = 'authtake-3rdparty',
        [string] $ClientSecret = 'thirdparty-secret-change-me-2024'
    )

    Invoke-RestMethod -Method Post `
        -Uri "$Keycloak/realms/$Realm/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'client_credentials'; client_id = $ClientId; client_secret = $ClientSecret } `
        -TimeoutSec 20
}

<# JWT govdesini (payload) cozer. Imza dogrulamasi API'nin isi. #>
function ConvertFrom-Jwt([string] $Token) {
    $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4) { $payload += '=' }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}
