using System.Net.Http.Json;
using System.Text.Json;
using Authtake.ThirdPartyClient.Models;
using Microsoft.Extensions.Logging;

namespace Authtake.ThirdPartyClient.Services;

public sealed class KeycloakOptions
{
    public const string SectionName = "Keycloak";

    public string Authority { get; set; } = string.Empty;
    public string Realm { get; set; } = string.Empty;
    public string ClientId { get; set; } = string.Empty;
    public string ClientSecret { get; set; } = string.Empty;

    public string TokenEndpoint =>
        $"{Authority.TrimEnd('/')}/realms/{Realm}/protocol/openid-connect/token";
}

/// <summary>
/// Client Credentials akisiyla Keycloak'tan access token alir.
///
/// Kullanici etkilesimi yoktur: ortada tarayici, giris ekrani veya sifre giren
/// bir insan bulunmaz. Uygulama kendi kimligini (client_id + client_secret) ile
/// dogrular ve kendi adina token alir. Keycloak bu token'i, client'a bagli
/// "service account" kullanicisi adina uretir.
/// </summary>
public sealed class KeycloakTokenService(
    HttpClient http,
    KeycloakOptions options,
    ILogger<KeycloakTokenService> logger)
{
    // Token'i sureci boyunca sakliyoruz. Her istek icin yeni token almak
    // gereksiz agir olurdu; Keycloak'i her cagrida yormanin da anlami yok.
    private string? _cachedToken;
    private DateTimeOffset _cachedUntil = DateTimeOffset.MinValue;

    // Token tam dolarken kullanmayalim: istek yolda iken gecersizlesebilir.
    private static readonly TimeSpan ExpiryMargin = TimeSpan.FromSeconds(30);

    /// <summary>Onbellekteki token gecerliyse onu, degilse yenisini dondurur.</summary>
    public async Task<(string Token, bool FromCache)> GetAccessTokenAsync(
        CancellationToken cancellationToken = default)
    {
        if (_cachedToken is not null && DateTimeOffset.UtcNow < _cachedUntil)
        {
            logger.LogDebug("Onbellekteki token kullanildi.");
            return (_cachedToken, true);
        }

        var response = await RequestTokenAsync(cancellationToken);
        _cachedToken = response.AccessToken;
        _cachedUntil = DateTimeOffset.UtcNow
            .AddSeconds(response.ExpiresInSeconds)
            .Subtract(ExpiryMargin);

        return (_cachedToken, false);
    }

    /// <summary>Onbellegi yok sayarak Keycloak'tan yeni token ister.</summary>
    public async Task<TokenResponse> RequestTokenAsync(
        CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, options.TokenEndpoint)
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "client_credentials",
                ["client_id"] = options.ClientId,
                ["client_secret"] = options.ClientSecret
            })
        };

        HttpResponseMessage response;
        try
        {
            response = await http.SendAsync(request, cancellationToken);
        }
        catch (HttpRequestException ex)
        {
            throw new InvalidOperationException(
                $"Keycloak'a ulasilamadi ({options.TokenEndpoint}). "
                + "Calisiyor mu? 'docker compose up -d'", ex);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken);

            if (!response.IsSuccessStatusCode)
            {
                // En sik sebep: client_secret yanlis ya da client'ta service
                // account kapali. Keycloak bunu error/error_description ile soyler.
                throw new InvalidOperationException(
                    $"Token alinamadi ({(int)response.StatusCode}). Keycloak yaniti: {body}");
            }

            return JsonSerializer.Deserialize<TokenResponse>(body)
                ?? throw new InvalidOperationException("Token yaniti cozulemedi.");
        }
    }

    /// <summary>Token'in govdesini (payload) acar. Imza dogrulamasi Backend'in isi.</summary>
    public static TokenClaims ReadClaims(string accessToken)
    {
        var parts = accessToken.Split('.');
        if (parts.Length != 3) return new TokenClaims();

        var payload = parts[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight(payload.Length + (4 - payload.Length % 4) % 4, '=');

        using var document = JsonDocument.Parse(Convert.FromBase64String(payload));
        var root = document.RootElement;

        return new TokenClaims
        {
            AuthorizedParty = ReadString(root, "azp"),
            Subject = ReadString(root, "sub"),
            PreferredUsername = ReadString(root, "preferred_username"),
            Audiences = ReadStringOrArray(root, "aud"),
            Roles = ReadRealmRoles(root),
            ExpiresAt = root.TryGetProperty("exp", out var exp) && exp.TryGetInt64(out var seconds)
                ? DateTimeOffset.FromUnixTimeSeconds(seconds)
                : null
        };
    }

    /// <summary>Keycloak realm rolleri `realm_access: { roles: [...] }` icinde gelir.</summary>
    private static IReadOnlyList<string> ReadRealmRoles(JsonElement root)
    {
        if (!root.TryGetProperty("realm_access", out var realmAccess)
            || !realmAccess.TryGetProperty("roles", out var roles)
            || roles.ValueKind is not JsonValueKind.Array)
        {
            return [];
        }

        return [.. roles.EnumerateArray().Select(r => r.GetString() ?? string.Empty)];
    }

    private static string? ReadString(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.String
            ? value.GetString()
            : null;

    // 'aud' claim'i tek bir metin de olabilir, dizi de - JWT standardi ikisine de izin verir.
    private static IReadOnlyList<string> ReadStringOrArray(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value)) return [];

        return value.ValueKind switch
        {
            JsonValueKind.String => [value.GetString() ?? string.Empty],
            JsonValueKind.Array => [.. value.EnumerateArray().Select(v => v.GetString() ?? string.Empty)],
            _ => []
        };
    }
}
