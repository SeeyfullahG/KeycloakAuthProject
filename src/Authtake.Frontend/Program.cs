using Authtake.Frontend.Auth;
using Authtake.Frontend.Components;
using Authtake.Frontend.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Components.Authorization;

var builder = WebApplication.CreateBuilder(args);

// Statik sunucu tarafli render (SSR) kullaniyoruz: bilesenler HttpContext'e
// erisebiliyor, boylece auth cookie'sindeki access token'a dogrudan ulasiyoruz.
builder.Services.AddRazorComponents();
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<AuthenticationStateProvider, HttpContextAuthenticationStateProvider>();
builder.Services.AddCascadingAuthenticationState();

builder.Services.AddKeycloakOidcAuthentication(builder.Configuration);

// PART 5 - otomatik token yenileme.
// Onbellek, ayni anda gelen isteklerin ayni refresh token'i tekrar tekrar
// kullanmaya calismasini engellemek icin (rotasyon acik oldugundan bu ikinci
// deneme reddedilir ve kullanici bosuna disari atilirdi).
builder.Services.AddMemoryCache();
builder.Services.AddHttpClient<TokenRefreshService>(client =>
    client.Timeout = TimeSpan.FromSeconds(15));

// PART 5 - otomatik token yenileme icin gerekli.
builder.Services.AddMemoryCache();
builder.Services.AddHttpClient<TokenRefreshService>(client =>
    client.Timeout = TimeSpan.FromSeconds(15));

builder.Services.AddHttpClient<BackendApiClient>(client =>
{
    client.BaseAddress = new Uri(builder.Configuration["BackendApi:BaseUrl"]
        ?? throw new InvalidOperationException("'BackendApi:BaseUrl' yapilandirmasi eksik."));
    client.Timeout = TimeSpan.FromSeconds(15);
});

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    app.UseHsts();
}

app.UseStaticFiles();
app.UseAuthentication();
app.UseAuthorization();
app.UseAntiforgery();

// --- Kimlik dogrulama uc noktalari -------------------------------------------
// Blazor bilesenleri icinden HTTP yonlendirmesi yapilamadigi icin login/logout
// islemleri ayri minimal API endpoint'leri olarak duruyor.

app.MapGet("/authentication/login", (string? returnUrl) =>
    Results.Challenge(
        new AuthenticationProperties { RedirectUri = SafeReturnUrl(returnUrl) },
        [OpenIdConnectDefaults.AuthenticationScheme]));

app.MapGet("/authentication/logout", () =>
    // Hem yerel cookie'yi siler hem Keycloak oturumunu sonlandirir (single logout).
    Results.SignOut(
        new AuthenticationProperties { RedirectUri = "/" },
        [CookieAuthenticationDefaults.AuthenticationScheme,
         OpenIdConnectDefaults.AuthenticationScheme]));

app.MapRazorComponents<App>();

app.Run();

// Acik yonlendirme (open redirect) acigini kapatmak icin sadece uygulama ici
// goreli yollara donusa izin veriyoruz.
static string SafeReturnUrl(string? returnUrl) =>
    !string.IsNullOrWhiteSpace(returnUrl)
    && Uri.IsWellFormedUriString(returnUrl, UriKind.Relative)
        ? returnUrl
        : "/";
