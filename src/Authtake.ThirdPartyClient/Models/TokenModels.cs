using System.Text.Json.Serialization;

namespace Authtake.ThirdPartyClient.Models;

/// <summary>
/// Keycloak'in token endpoint'inden donen yanit (RFC 6749).
/// Client Credentials akisinda refresh_token gelmez: kullanici oturumu yoktur,
/// token dolunca istemci ayni sekilde yenisini ister.
/// </summary>
public sealed record TokenResponse
{
    [JsonPropertyName("access_token")]
    public required string AccessToken { get; init; }

    [JsonPropertyName("token_type")]
    public string TokenType { get; init; } = "Bearer";

    [JsonPropertyName("expires_in")]
    public int ExpiresInSeconds { get; init; }

    [JsonPropertyName("scope")]
    public string? Scope { get; init; }
}

/// <summary>Access token'in govdesinden okunan, gostermek istedigimiz alanlar.</summary>
public sealed record TokenClaims
{
    public string? AuthorizedParty { get; init; }
    public IReadOnlyList<string> Audiences { get; init; } = [];
    public IReadOnlyList<string> Roles { get; init; } = [];
    public string? Subject { get; init; }
    public string? PreferredUsername { get; init; }
    public DateTimeOffset? ExpiresAt { get; init; }
}

/// <summary>Backend API cagrisinin sonucu.</summary>
public sealed record ApiCallResult(int StatusCode, string Body)
{
    public bool IsSuccess => StatusCode is >= 200 and < 300;

    public string Describe() => StatusCode switch
    {
        200 => "200 OK - istek basarili",
        401 => "401 Unauthorized - token yok, gecersiz veya suresi dolmus",
        403 => "403 Forbidden - token gecerli ama rol yetersiz",
        0   => "Baglanti kurulamadi",
        _   => StatusCode.ToString()
    };
}
