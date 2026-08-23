using System.Collections.Concurrent;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Caching.Memory;

namespace Authtake.Frontend.Auth;

/// <summary>Keycloak'in token endpoint'inden donen yenileme yaniti.</summary>
public sealed record RefreshedTokens
{
    [JsonPropertyName("access_token")]
    public required string AccessToken { get; init; }

    [JsonPropertyName("refresh_token")]
    public string? RefreshToken { get; init; }

    [JsonPropertyName("id_token")]
    public string? IdToken { get; init; }

    [JsonPropertyName("expires_in")]
    public int ExpiresInSeconds { get; init; }

    public DateTimeOffset ExpiresAt { get; init; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// Access token'i refresh token ile yeniler.
///
/// PARALEL ISTEK SORUNU
/// Realm'de refresh token rotasyonu acik: her yenilemede yeni bir refresh token
/// verilir ve eskisi aninda gecersizlesir. Bir sayfa ayni anda birkac istek
/// atarsa (ki statik SSR'da bile olur), hepsi ellerindeki AYNI eski refresh
/// token ile yenilemeye kalkar; ilki basarili olur, digerleri "gecersiz token"
/// hatasi alir ve kullanici bosuna disari atilir.
///
/// Iki onlem birlikte kullaniliyor:
///   1. Kullanici basina kilit  - ayni anda yalnizca bir yenileme calisir
///   2. Kisa omurlu onbellek    - yarisi kaybeden istek, kazananin aldigi yeni
///                                token'lari onbellekten okur, tekrar denemez
/// </summary>
public sealed class TokenRefreshService(
    HttpClient http,
    KeycloakOptions keycloak,
    IMemoryCache cache,
    ILogger<TokenRefreshService> logger)
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Locks = new();
    private static readonly TimeSpan CacheWindow = TimeSpan.FromSeconds(30);

    /// <param name="userKey">Kilit ve onbellek anahtari (kullanicinin 'sub' claim'i).</param>
    /// <returns>Yeni token'lar; yenileme reddedildiyse null.</returns>
    public async Task<RefreshedTokens?> RefreshAsync(string refreshToken, string userKey)
    {
        var cacheKey = $"refresh:{refreshToken}";
        if (cache.TryGetValue<RefreshedTokens>(cacheKey, out var cached) && cached is not null)
        {
            logger.LogDebug("Yenileme onbellekten karsilandi (paralel istek).");
            return cached;
        }

        var gate = Locks.GetOrAdd(userKey, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync();
        try
        {
            // Kilidi beklerken baska bir istek yenilemis olabilir.
            if (cache.TryGetValue(cacheKey, out cached) && cached is not null) return cached;

            var refreshed = await RequestAsync(refreshToken);
            if (refreshed is not null)
            {
                // Eski token'i anahtar olarak sakliyoruz: ayni eski token'la gelen
                // diger istekler de yeni token'lara ulasabilsin.
                cache.Set(cacheKey, refreshed, CacheWindow);
            }

            return refreshed;
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<RefreshedTokens?> RequestAsync(string refreshToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Post, $"{keycloak.Issuer}/protocol/openid-connect/token")
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["client_id"] = keycloak.ClientId,
                ["refresh_token"] = refreshToken
            })
        };

        try
        {
            using var response = await http.SendAsync(request);
            var body = await response.Content.ReadAsStringAsync();

            if (!response.IsSuccessStatusCode)
            {
                // En sik sebep: refresh token'in de suresi dolmus veya kullanici
                // Keycloak tarafinda cikis yapmis. Kullanici yeniden giris yapmali.
                logger.LogInformation(
                    "Token yenileme reddedildi ({Status}): {Body}", (int)response.StatusCode, body);
                return null;
            }

            var tokens = System.Text.Json.JsonSerializer.Deserialize<RefreshedTokens>(body);
            if (tokens is null) return null;

            return tokens with
            {
                ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(tokens.ExpiresInSeconds)
            };
        }
        catch (HttpRequestException ex)
        {
            logger.LogWarning(ex, "Keycloak'a ulasilamadi; token yenilenemedi.");
            return null;
        }
    }
}
