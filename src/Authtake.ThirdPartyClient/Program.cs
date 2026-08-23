using Authtake.ThirdPartyClient.Reporting;
using Authtake.ThirdPartyClient.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

// ---------------------------------------------------------------------------
// 3rd Party API istemcisi - Client Credentials akisi
//
// Bu uygulamanin frontend'den farki: ortada KULLANICI YOK. Tarayici, giris
// ekrani, sifre giren bir insan yok. Uygulama kendi kimligiyle (client_id +
// client_secret) Keycloak'tan token alir ve Backend API'ye o token'la gider.
// Gercek hayatta bu, "bir sirketin sistemi bizim API'mize baglaniyor"
// senaryosudur: gece 03:00'te calisan bir entegrasyon isi gibi.
// ---------------------------------------------------------------------------

// Icerik kokunu uygulamanin kendi klasorune sabitliyoruz. Varsayilan deger
// calisma dizinidir; 'dotnet run --project ...' cozum kokunden calistirildiginda
// appsettings.json orada aranir ve bulunamaz.
var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory
});

var keycloak = builder.Configuration.GetSection(KeycloakOptions.SectionName).Get<KeycloakOptions>()
    ?? throw new InvalidOperationException("'Keycloak' yapilandirma bolumu eksik.");
var backend = builder.Configuration.GetSection(BackendApiOptions.SectionName).Get<BackendApiOptions>()
    ?? throw new InvalidOperationException("'BackendApi' yapilandirma bolumu eksik.");

builder.Services.AddSingleton(keycloak);
builder.Services.AddSingleton(backend);
builder.Services.AddSingleton<ConsoleReport>();

builder.Services.AddHttpClient<KeycloakTokenService>(client =>
    client.Timeout = TimeSpan.FromSeconds(20));

builder.Services.AddHttpClient<BackendApiClient>(client =>
{
    client.BaseAddress = new Uri(backend.BaseUrl);
    client.Timeout = TimeSpan.FromSeconds(20);
});

using var host = builder.Build();

var report = host.Services.GetRequiredService<ConsoleReport>();
var tokens = host.Services.GetRequiredService<KeycloakTokenService>();
var api = host.Services.GetRequiredService<BackendApiClient>();

Console.WriteLine();
Console.WriteLine("  AUTHTAKE - 3rd Party API Istemcisi (Client Credentials)");
Console.WriteLine("  Kullanici etkilesimi yok: servis kendi kimligiyle token alir.");

report.Title("Yapilandirma");
report.Info("Keycloak token endpoint", keycloak.TokenEndpoint);
report.Info("Client ID", keycloak.ClientId);
report.Info("Client secret", new string('*', Math.Min(keycloak.ClientSecret.Length, 12)));
report.Info("Backend API", backend.BaseUrl);

// ---------------------------------------------------------------------------
// ADIM 1 - Keycloak'tan token al
// ---------------------------------------------------------------------------
report.Title("ADIM 1 - Keycloak'tan token isteniyor");
report.Detail("POST grant_type=client_credentials  (client_id + client_secret)");

string accessToken;
try
{
    var tokenResponse = await tokens.RequestTokenAsync();
    accessToken = tokenResponse.AccessToken;

    report.Check(!string.IsNullOrWhiteSpace(accessToken), "Access token alindi");
    report.Check(tokenResponse.TokenType.Equals("Bearer", StringComparison.OrdinalIgnoreCase),
        $"token_type = {tokenResponse.TokenType}");
    report.Info("expires_in", $"{tokenResponse.ExpiresInSeconds} saniye");

    var claims = KeycloakTokenService.ReadClaims(accessToken);
    report.Step("Token'in icinde ne var?");
    report.Info("azp (isteyen uygulama)", claims.AuthorizedParty);
    report.Info("preferred_username", claims.PreferredUsername);
    report.Info("aud (hedef kitle)", string.Join(", ", claims.Audiences));
    report.Info("roller", string.Join(", ", claims.Roles));
    report.Info("gecerlilik sonu", claims.ExpiresAt?.ToLocalTime().ToString("dd.MM.yyyy HH:mm:ss"));

    report.Check(claims.AuthorizedParty == keycloak.ClientId,
        $"Token bu client icin uretildi ({keycloak.ClientId})");
    report.Check(claims.Audiences.Contains("authtake-backend"),
        "Audience 'authtake-backend' iceriyor - Backend bu token'i kabul edebilir");
    report.Check(claims.Roles.Contains("admin"),
        "Service account 'admin' rolune sahip");
    report.Check(claims.PreferredUsername?.StartsWith("service-account-") is true,
        "Kimlik bir service account (insan kullanici degil)");
}
catch (InvalidOperationException ex)
{
    report.Error(ex.Message);
    Console.WriteLine();
    Console.WriteLine("  Keycloak calisiyor mu? 'docker compose up -d'");
    return 1;
}

// ---------------------------------------------------------------------------
// ADIM 2 - Backend API'ye token ile istek
// ---------------------------------------------------------------------------
report.Title("ADIM 2 - Backend API cagriliyor (Authorization: Bearer ...)");

foreach (var call in new[]
{
    (Path: "/api/public/hello", Expected: 200, Note: "token gerektirmez"),
    (Path: "/api/hello/secure", Expected: 200, Note: "gecerli token yeterli"),
    (Path: "/api/admin/data",   Expected: 200, Note: "admin rolu gerekli")
})
{
    var result = await api.GetAsync(call.Path, accessToken);
    report.Step($"GET {call.Path}   ({call.Note})");
    report.Check(result.StatusCode == call.Expected,
        $"{result.Describe()}  [beklenen {call.Expected}]");

    if (result.StatusCode == 0) report.Body(result.Body);
}

// ---------------------------------------------------------------------------
// ADIM 3 - Backend'in donen veriyi nasil isaretledigi
// ---------------------------------------------------------------------------
report.Title("ADIM 3 - Backend yaniti isleniyor");

var adminResult = await api.GetAsync("/api/admin/data", accessToken);
if (adminResult.IsSuccess)
{
    var username = BackendApiClient.ReadField(adminResult.Body, "user", "username");
    var isServiceAccount = BackendApiClient.ReadField(adminResult.Body, "user", "isServiceAccount");
    var accessedVia = BackendApiClient.ReadField(adminResult.Body, "data", "accessedVia");
    var message = BackendApiClient.ReadField(adminResult.Body, "message");

    report.Info("message", message);
    report.Info("user.username", username);
    report.Info("user.isServiceAccount", isServiceAccount);
    report.Info("data.accessedVia", accessedVia);

    report.Check(isServiceAccount == "true",
        "Backend istegi service account olarak tanidi");
    report.Check(accessedVia == "client_credentials",
        "Backend akisi 'client_credentials' olarak isaretledi");

    report.Step("Ham yanit (ilk satirlar)");
    var pretty = BackendApiClient.Pretty(adminResult.Body);
    report.Body(string.Join('\n', pretty.Split('\n').Take(12)) + "\n      ...");
}
else
{
    report.Error($"Admin verisi alinamadi: {adminResult.Describe()}");
}

// ---------------------------------------------------------------------------
// ADIM 4 - Negatif kontrol: token gondermezsek ne olur?
// ---------------------------------------------------------------------------
report.Title("ADIM 4 - Negatif kontrol: token gonderilmiyor");
report.Detail("Ayni adres, ama Authorization basligi yok.");

var noToken = await api.GetAsync("/api/admin/data", accessToken: null);
report.Check(noToken.StatusCode == 401,
    $"{noToken.Describe()}  [beklenen 401]");

// ---------------------------------------------------------------------------
// ADIM 5 - Token onbellegi
// ---------------------------------------------------------------------------
report.Title("ADIM 5 - Token onbellegi");
report.Detail("Her istekte yeni token almak gereksiz; suresi dolana kadar ayni token kullanilir.");

var (first, firstFromCache) = await tokens.GetAccessTokenAsync();
var (second, secondFromCache) = await tokens.GetAccessTokenAsync();

report.Check(!firstFromCache, "Ilk cagri Keycloak'a gitti");
report.Check(secondFromCache, "Ikinci cagri onbellekten karsilandi (Keycloak'a gidilmedi)");
report.Check(first == second, "Iki cagri da ayni token'i dondurdu");

return report.Summary();
