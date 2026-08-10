namespace Authtake.BackendApi.Models;

/// <summary>
/// Access token claim'lerinden cikarilan kullanici bilgisi.
/// Service account token'larinda email/name bos olabilir.
/// </summary>
public sealed record UserInfo
{
    public string? Id { get; init; }
    public string? Username { get; init; }
    public string? Email { get; init; }
    public string? Name { get; init; }
    public IReadOnlyList<string> Roles { get; init; } = [];

    /// <summary>Token'i isteyen client (azp claim'i) - 3rd party cagrilarini ayirt etmek icin.</summary>
    public string? ClientId { get; init; }

    /// <summary>Client Credentials flow ile alinmis bir service account token'i mi?</summary>
    public bool IsServiceAccount { get; init; }
}

/// <summary>Basarili yanit zarfi (200 OK).</summary>
public sealed record ApiResponse
{
    public required string Message { get; init; }
    public UserInfo? User { get; init; }
    public object? Data { get; init; }
    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.UtcNow;
}

/// <summary>Standartlastirilmis hata yaniti (401 / 403 / digerleri).</summary>
public sealed record ErrorResponse
{
    public required string Error { get; init; }
    public required string Message { get; init; }
    public required int Status { get; init; }
    public string? Path { get; init; }
    public DateTimeOffset Timestamp { get; init; } = DateTimeOffset.UtcNow;
}
