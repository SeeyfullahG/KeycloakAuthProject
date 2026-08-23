using System.Net.Mime;
using System.Security.Claims;
using System.Text.Json;
using Authtake.BackendApi.Models;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

namespace Authtake.BackendApi.Auth;

public sealed class KeycloakOptions
{
    public const string SectionName = "Keycloak";

    /// <summary>Ornek: http://localhost:8080</summary>
    public string Authority { get; set; } = string.Empty;
    public string Realm { get; set; } = string.Empty;
    /// <summary>Token'in `aud` claim'inde bulunmasi gereken deger.</summary>
    public string Audience { get; set; } = string.Empty;
    /// <summary>Gelistirmede Keycloak HTTP uzerinden calistigi icin false.</summary>
    public bool RequireHttpsMetadata { get; set; }

    public string Issuer => $"{Authority.TrimEnd('/')}/realms/{Realm}";
}

public static class KeycloakAuthenticationExtensions
{
    public const string AdminPolicy = "RequireAdminRole";
    public const string AuthenticatedPolicy = "RequireAuthenticatedUser";

    public static IServiceCollection AddKeycloakJwtAuthentication(
        this IServiceCollection services, IConfiguration configuration)
    {
        var keycloak = configuration.GetSection(KeycloakOptions.SectionName).Get<KeycloakOptions>()
            ?? throw new InvalidOperationException(
                $"'{KeycloakOptions.SectionName}' yapilandirma bolumu eksik.");

        services.AddSingleton(keycloak);

        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                options.Authority = keycloak.Issuer;
                options.Audience = keycloak.Audience;
                options.RequireHttpsMetadata = keycloak.RequireHttpsMetadata;
                options.MetadataAddress =
                    $"{keycloak.Issuer}/.well-known/openid-configuration";

                // Varsayilan olarak JwtBearer, JWT claim adlarini eski SOAP/XML
                // sema URI'lerine cevirir (email -> ClaimTypes.Email, sub ->
                // NameIdentifier). Bu, OIDC claim adlariyla dogrudan calismayi
                // engelliyor; ham adlari koruyoruz.
                options.MapInboundClaims = false;

                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidIssuer = keycloak.Issuer,
                    ValidateAudience = true,
                    ValidAudience = keycloak.Audience,
                    ValidateLifetime = true,
                    ValidateIssuerSigningKey = true,
                    // Suresi dolmus token gercekten 401 donsun diye varsayilan
                    // 5 dakikalik tolerans kaldirildi (PART 5 token expiry testi).
                    ClockSkew = TimeSpan.Zero,
                    NameClaimType = "preferred_username",
                    RoleClaimType = ClaimTypes.Role
                };

                options.Events = new JwtBearerEvents
                {
                    OnTokenValidated = MapKeycloakRealmRoles,
                    OnChallenge = WriteUnauthorizedResponse,
                    OnForbidden = WriteForbiddenResponse
                };
            });

        services.AddAuthorizationBuilder()
            .AddPolicy(AuthenticatedPolicy, p => p.RequireAuthenticatedUser())
            // Korumali veriye iki taraf erisebilir: 'admin' rolu olan gercek
            // kullanicilar ve 'service-api' rolu olan servis hesaplari.
            //
            // Servis hesabina 'admin' vermek yerine ayri bir rol tanimlamamizin
            // sebebi en az yetki ilkesi: ileride 'admin' rolune yeni ve daha
            // tehlikeli yetkiler eklendiginde 3rd party bunlari otomatik olarak
            // kazanmaz. Insan yetkileriyle makine yetkileri ayri kalir.
            .AddPolicy(AdminPolicy, p => p
                .RequireAuthenticatedUser()
                .RequireRole("admin", "service-api"));

        return services;
    }

    /// <summary>
    /// Keycloak rolleri `realm_access: { roles: [...] }` seklinde ic ice bir JSON
    /// nesnesinde tasir; ASP.NET Core bunu tanimaz. Duz ClaimTypes.Role claim'lerine
    /// aciyoruz ki [Authorize(Roles = "admin")] ve RequireRole calissin.
    /// </summary>
    private static Task MapKeycloakRealmRoles(TokenValidatedContext context)
    {
        if (context.Principal?.Identity is not ClaimsIdentity identity)
            return Task.CompletedTask;

        var realmAccess = context.Principal.FindFirst("realm_access")?.Value;
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
                .CreateLogger(typeof(KeycloakAuthenticationExtensions))
                .LogWarning(ex, "realm_access claim'i ayristirilamadi; roller atanmadi.");
        }

        return Task.CompletedTask;
    }

    // Token yok / gecersiz / suresi dolmus -> 401
    private static Task WriteUnauthorizedResponse(JwtBearerChallengeContext context)
    {
        // Varsayilan WWW-Authenticate yanitini bastirip kendi JSON'umuzu yaziyoruz.
        context.HandleResponse();

        var message = context.AuthenticateFailure switch
        {
            SecurityTokenExpiredException => "Access token has expired. Use the refresh token to obtain a new one.",
            SecurityTokenInvalidAudienceException => "Token audience is not valid for this API.",
            SecurityTokenInvalidIssuerException => "Token was not issued by the expected identity provider.",
            SecurityTokenInvalidSignatureException => "Token signature is not valid.",
            not null => "Token is invalid.",
            _ => "Token is missing or invalid."
        };

        return WriteErrorAsync(context.HttpContext, StatusCodes.Status401Unauthorized, "Unauthorized", message);
    }

    // Token gecerli ama rol yetersiz -> 403
    private static Task WriteForbiddenResponse(ForbiddenContext context) =>
        WriteErrorAsync(context.HttpContext, StatusCodes.Status403Forbidden, "Forbidden",
            "You are authenticated but do not have the required role to access this resource.");

    private static async Task WriteErrorAsync(
        HttpContext http, int status, string error, string message)
    {
        if (http.Response.HasStarted) return;

        http.Response.StatusCode = status;
        http.Response.ContentType = MediaTypeNames.Application.Json;

        await http.Response.WriteAsJsonAsync(new ErrorResponse
        {
            Error = error,
            Message = message,
            Status = status,
            Path = http.Request.Path.Value
        });
    }
}
