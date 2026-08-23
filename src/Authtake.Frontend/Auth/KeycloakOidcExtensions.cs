using System.Globalization;
using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;

namespace Authtake.Frontend.Auth;

public sealed class KeycloakOptions
{
    public const string SectionName = "Keycloak";

    public string Authority { get; set; } = string.Empty;
    public string Realm { get; set; } = string.Empty;
    public string ClientId { get; set; } = string.Empty;
    public bool RequireHttpsMetadata { get; set; }

    public string Issuer => $"{Authority.TrimEnd('/')}/realms/{Realm}";
}

public static class KeycloakOidcExtensions
{
    public const string AdminPolicy = "RequireAdminRole";

    /// <summary>Access token'i dolmadan bu kadar once yenile.</summary>
    private static readonly TimeSpan RefreshMargin = TimeSpan.FromMinutes(1);

    public static IServiceCollection AddKeycloakOidcAuthentication(
        this IServiceCollection services, IConfiguration configuration)
    {
        var keycloak = configuration.GetSection(KeycloakOptions.SectionName).Get<KeycloakOptions>()
            ?? throw new InvalidOperationException(
                $"'{KeycloakOptions.SectionName}' yapilandirma bolumu eksik.");

        services.AddSingleton(keycloak);

        services.AddAuthentication(options =>
        {
            // Oturum cookie ile tasinir; giris gerektiginde Keycloak'a yonlendirilir.
            options.DefaultScheme = CookieAuthenticationDefaults.AuthenticationScheme;
            options.DefaultChallengeScheme = OpenIdConnectDefaults.AuthenticationScheme;
        })
        .AddCookie(options =>
        {
            options.Cookie.Name = "authtake.frontend";
            options.Cookie.HttpOnly = true;
            options.Cookie.SameSite = SameSiteMode.Lax; // OIDC geri donusu icin gerekli
            options.SlidingExpiration = true;

            // Rol yetersizliginde ASP.NET Core varsayilan olarak
            // /Account/AccessDenied adresine yonlendirir; bizde boyle bir sayfa
            // olmadigi icin kullanici 404 gorurdu. Kendi 403 sayfamiza gonderiyoruz.
            options.AccessDeniedPath = "/access-denied";

            // PART 5 - otomatik token yenileme.
            // Her istekte cookie dogrulanirken calisir; access token'in omru
            // dolmak uzereyse refresh token ile sessizce yenilenir.
            options.Events.OnValidatePrincipal = RefreshAccessTokenIfNeeded;
        })
        .AddOpenIdConnect(options =>
        {
            options.Authority = keycloak.Issuer;
            options.ClientId = keycloak.ClientId;
            options.RequireHttpsMetadata = keycloak.RequireHttpsMetadata;

            // Authorization Code + PKCE: tarayicida calisan public client oldugumuz
            // icin client_secret yok, guvenligi PKCE sagliyor.
            options.ResponseType = OpenIdConnectResponseType.Code;
            options.UsePkce = true;

            // Gelistirmede HTTP uzerinde calisiyoruz. Varsayilan ayar, kodu
            // Keycloak'tan bize siteler arasi bir POST ile geri gonderir
            // (response_mode=form_post) ve bunun icin correlation/nonce
            // cookie'lerini SameSite=None yazar. SameSite=None ancak Secure
            // (HTTPS) cookie'lerde gecerlidir; HTTP'de cookie dusuyor ve donuste
            // dogrulama yapilamadigi icin 400 aliniyor.
            // Cozum: kodu normal yonlendirmeyle (query) al ve cookie'leri Lax yap.
            // Uretimde HTTPS ile form_post + SameSite=None tercih edilmelidir.
            options.ResponseMode = OpenIdConnectResponseMode.Query;
            options.CorrelationCookie.SameSite = SameSiteMode.Lax;
            options.NonceCookie.SameSite = SameSiteMode.Lax;

            // Ayni gerekce: HTTP'de cookie'yi Secure isaretlemek onu geri
            // gonderilemez yapar. SameAsRequest, HTTPS'e gecildiginde otomatik
            // olarak yeniden Secure isaretler.
            options.CorrelationCookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
            options.NonceCookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;

            // Access ve refresh token'lari auth cookie'sinde sakla; Backend API
            // cagrilarinda access token'a ihtiyacimiz var.
            options.SaveTokens = true;
            options.GetClaimsFromUserInfoEndpoint = false;

            options.Scope.Clear();
            options.Scope.Add("openid");
            options.Scope.Add("profile");
            options.Scope.Add("email");

            options.CallbackPath = "/signin-oidc";
            options.SignedOutCallbackPath = "/signout-callback-oidc";
            options.SignedOutRedirectUri = "/";

            // Backend API ile ayni gerekce: OIDC claim adlarini oldugu gibi koru.
            options.MapInboundClaims = false;
            options.TokenValidationParameters.NameClaimType = "preferred_username";
            options.TokenValidationParameters.RoleClaimType = ClaimTypes.Role;

            options.Events.OnTokenValidated = MapKeycloakRealmRoles;
        });

        services.AddAuthorizationBuilder()
            .AddPolicy(AdminPolicy, p => p.RequireAuthenticatedUser().RequireRole("admin"));

        return services;
    }

    /// <summary>
    /// Access token'in suresi dolmak uzereyse refresh token ile yeniler ve
    /// yeni token'lari oturum cookie'sine yazar. Kullanici bunu hic fark etmez.
    ///
    /// Yenileme basarisiz olursa (refresh token'in de suresi dolmus, ya da
    /// kullanici Keycloak tarafinda cikis yapmis) oturum sonlandirilir; bir
    /// sonraki korumali sayfa istegi kullaniciyi giris ekranina goturur.
    /// </summary>
    private static async Task RefreshAccessTokenIfNeeded(CookieValidatePrincipalContext context)
    {
        var expiresAt = context.Properties.GetTokenValue("expires_at");
        if (!DateTimeOffset.TryParse(expiresAt, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind, out var expiry))
        {
            return; // Token saklanmamis; yapacak bir sey yok.
        }

        // Tam dolma anini beklemiyoruz: istek yoldayken gecersizlesmesin diye
        // son bir dakikada onden yeniliyoruz.
        if (DateTimeOffset.UtcNow < expiry - RefreshMargin) return;

        var services = context.HttpContext.RequestServices;
        var logger = services.GetRequiredService<ILoggerFactory>()
            .CreateLogger(typeof(KeycloakOidcExtensions));

        var refreshToken = context.Properties.GetTokenValue("refresh_token");
        if (string.IsNullOrWhiteSpace(refreshToken))
        {
            logger.LogInformation("Access token doldu ve refresh token yok; oturum kapatiliyor.");
            await SignOutAsync(context);
            return;
        }

        var userKey = context.Principal?.FindFirstValue("sub") ?? refreshToken;
        var refreshed = await services.GetRequiredService<TokenRefreshService>()
            .RefreshAsync(refreshToken, userKey);

        if (refreshed is null)
        {
            logger.LogInformation("Token yenilenemedi; oturum kapatiliyor.");
            await SignOutAsync(context);
            return;
        }

        // Yeni token'lari sakla. Rotasyon acik oldugu icin refresh token da
        // degisir; eskisini saklamak bir sonraki yenilemeyi bozardi.
        var tokens = new List<AuthenticationToken>
        {
            new() { Name = "access_token", Value = refreshed.AccessToken },
            new() { Name = "expires_at", Value = refreshed.ExpiresAt.ToString("o", CultureInfo.InvariantCulture) },
            new() { Name = "refresh_token", Value = refreshed.RefreshToken ?? refreshToken }
        };

        var idToken = refreshed.IdToken ?? context.Properties.GetTokenValue("id_token");
        if (!string.IsNullOrWhiteSpace(idToken))
            tokens.Add(new AuthenticationToken { Name = "id_token", Value = idToken });

        context.Properties.StoreTokens(tokens);

        // Cookie'nin guncellenmis haliyle yeniden yazilmasini istiyoruz.
        context.ShouldRenew = true;

        logger.LogInformation("Access token yenilendi; yeni gecerlilik: {Expiry:o}", refreshed.ExpiresAt);
    }

    private static async Task SignOutAsync(CookieValidatePrincipalContext context)
    {
        context.RejectPrincipal();
        await context.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
    }

    /// <summary>
    /// Keycloak realm rollerini duz <see cref="ClaimTypes.Role"/> claim'lerine
    /// acar ki AuthorizeView ve [Authorize(Roles = "...")] calissin.
    ///
    /// Onemli ayrinti: Keycloak <c>realm_access.roles</c> bilgisini varsayilan
    /// olarak yalnizca ACCESS token'a koyar; oturumu kuran id_token'da bu claim
    /// bulunmaz. OIDC handler ise kimligi id_token'dan uretir. Bu yuzden rolleri
    /// dogrudan access token'in govdesinden okuyoruz.
    /// </summary>
    private static Task MapKeycloakRealmRoles(TokenValidatedContext context)
    {
        if (context.Principal?.Identity is not ClaimsIdentity identity)
            return Task.CompletedTask;

        // Once access token, yoksa id_token'daki claim (bazi kurulumlarda mevcut).
        var realmAccess = ReadRealmAccess(context.TokenEndpointResponse?.AccessToken)
                          ?? context.Principal.FindFirst("realm_access")?.Value;

        if (string.IsNullOrWhiteSpace(realmAccess))
            return Task.CompletedTask;

        try
        {
            using var document = JsonDocument.Parse(realmAccess);
            if (!document.RootElement.TryGetProperty("roles", out var roles)
                || roles.ValueKind is not JsonValueKind.Array)
                return Task.CompletedTask;

            foreach (var role in roles.EnumerateArray())
            {
                var value = role.GetString();
                if (!string.IsNullOrWhiteSpace(value) && !identity.HasClaim(ClaimTypes.Role, value))
                    identity.AddClaim(new Claim(ClaimTypes.Role, value));
            }
        }
        catch (JsonException ex)
        {
            context.HttpContext.RequestServices
                .GetRequiredService<ILoggerFactory>()
                .CreateLogger(typeof(KeycloakOidcExtensions))
                .LogWarning(ex, "realm_access claim'i ayristirilamadi; roller atanmadi.");
        }

        return Task.CompletedTask;
    }

    /// <summary>JWT govdesinden ham realm_access nesnesini cikarir.</summary>
    private static string? ReadRealmAccess(string? jwt)
    {
        if (string.IsNullOrWhiteSpace(jwt)) return null;

        var parts = jwt.Split('.');
        if (parts.Length != 3) return null;

        try
        {
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + (4 - payload.Length % 4) % 4, '=');

            using var document = JsonDocument.Parse(Convert.FromBase64String(payload));
            return document.RootElement.TryGetProperty("realm_access", out var realmAccess)
                ? realmAccess.GetRawText()
                : null;
        }
        catch (Exception ex) when (ex is FormatException or JsonException)
        {
            return null;
        }
    }
}
