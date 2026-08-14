using System.Net.Http.Headers;
using System.Text.Json;

namespace Authtake.Frontend.Services;

/// <summary>Backend API cagrisinin ham sonucu - status code'u da gostermek istiyoruz.</summary>
public sealed record ApiCallResult(int StatusCode, string Body, bool Succeeded)
{
    /// <summary>Yaniti okunakli hale getirir; JSON degilse oldugu gibi birakir.</summary>
    public string PrettyBody
    {
        get
        {
            if (string.IsNullOrWhiteSpace(Body)) return "(bos yanit)";
            try
            {
                using var doc = JsonDocument.Parse(Body);
                return JsonSerializer.Serialize(doc, new JsonSerializerOptions { WriteIndented = true });
            }
            catch (JsonException) { return Body; }
        }
    }

    public string StatusText => StatusCode switch
    {
        200 => "200 OK - istek basarili",
        401 => "401 Unauthorized - token yok, gecersiz veya suresi dolmus",
        403 => "403 Forbidden - token gecerli ama rol yetersiz",
        0   => "Baglanti kurulamadi",
        _   => $"{StatusCode}"
    };
}

public sealed class BackendApiClient(HttpClient http, ILogger<BackendApiClient> logger)
{
    /// <summary>
    /// Backend API'ye istek gonderir. accessToken null ise Authorization header'i
    /// hic eklenmez - "token gondermezsem ne olur?" senaryosunu gostermek icin.
    /// </summary>
    public async Task<ApiCallResult> GetAsync(string path, string? accessToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, path);
        if (!string.IsNullOrWhiteSpace(accessToken))
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);

        try
        {
            using var response = await http.SendAsync(request);
            var body = await response.Content.ReadAsStringAsync();
            return new ApiCallResult((int)response.StatusCode, body, response.IsSuccessStatusCode);
        }
        catch (HttpRequestException ex)
        {
            logger.LogError(ex, "Backend API'ye ulasilamadi: {Path}", path);
            return new ApiCallResult(0,
                $"Backend API'ye baglanilamadi ({http.BaseAddress}{path.TrimStart('/')}). "
                + "API calisiyor mu? 'dotnet run --project src/Authtake.BackendApi'", false);
        }
    }
}
