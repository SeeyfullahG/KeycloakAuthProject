using System.Net.Http.Headers;
using System.Text.Json;
using Authtake.ThirdPartyClient.Models;

namespace Authtake.ThirdPartyClient.Services;

public sealed class BackendApiOptions
{
    public const string SectionName = "BackendApi";
    public string BaseUrl { get; set; } = string.Empty;
}

/// <summary>
/// Backend API'ye istek atar. Token'i "Authorization: Bearer &lt;token&gt;"
/// basligiyla tasir - Backend'in bekledigi tek sey budur; istegi kimin
/// gonderdigi (tarayici mi, servis mi) onu ilgilendirmez.
/// </summary>
public sealed class BackendApiClient(HttpClient http)
{
    public async Task<ApiCallResult> GetAsync(
        string path, string? accessToken, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, path);

        if (!string.IsNullOrWhiteSpace(accessToken))
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

        try
        {
            using var response = await http.SendAsync(request, cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            return new ApiCallResult((int)response.StatusCode, body);
        }
        catch (HttpRequestException ex)
        {
            return new ApiCallResult(0,
                $"Backend API'ye baglanilamadi ({http.BaseAddress}{path.TrimStart('/')}): {ex.Message}");
        }
    }

    /// <summary>Yaniti okunakli hale getirir; JSON degilse oldugu gibi birakir.</summary>
    public static string Pretty(string body)
    {
        if (string.IsNullOrWhiteSpace(body)) return "(bos yanit)";

        try
        {
            using var document = JsonDocument.Parse(body);
            return JsonSerializer.Serialize(document, new JsonSerializerOptions { WriteIndented = true });
        }
        catch (JsonException)
        {
            return body;
        }
    }

    /// <summary>Yanit govdesindeki bir alani okur; yoksa null doner.</summary>
    public static string? ReadField(string body, params string[] path)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var element = document.RootElement;

            foreach (var segment in path)
            {
                if (!element.TryGetProperty(segment, out element)) return null;
            }

            return element.ValueKind switch
            {
                JsonValueKind.String => element.GetString(),
                JsonValueKind.True or JsonValueKind.False => element.GetRawText(),
                JsonValueKind.Number => element.GetRawText(),
                _ => element.GetRawText()
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
