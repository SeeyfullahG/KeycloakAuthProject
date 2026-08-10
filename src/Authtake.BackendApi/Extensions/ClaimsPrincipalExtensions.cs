using System.Security.Claims;
using Authtake.BackendApi.Models;

namespace Authtake.BackendApi.Extensions;

public static class ClaimsPrincipalExtensions
{
    /// <summary>
    /// Dogrulanmis JWT'nin claim'lerini UserInfo'ya cevirir.
    /// Roller KeycloakClaimsTransformer tarafindan realm_access.roles'tan
    /// ClaimTypes.Role'e tasinmis olarak gelir.
    /// </summary>
    public static UserInfo ToUserInfo(this ClaimsPrincipal principal)
    {
        var clientId = principal.FindFirstValue("azp");
        var username = principal.FindFirstValue("preferred_username");

        return new UserInfo
        {
            Id = principal.FindFirstValue("sub"),
            Username = username,
            Email = principal.FindFirstValue("email"),
            Name = principal.FindFirstValue("name"),
            Roles = principal.FindAll(ClaimTypes.Role)
                             .Select(c => c.Value)
                             .Distinct()
                             .OrderBy(r => r, StringComparer.Ordinal)
                             .ToList(),
            ClientId = clientId,
            // Keycloak service account kullanicilarini "service-account-<clientId>"
            // olarak adlandirir; kullanici etkilesimi olmadan alinan token'i bu ayirt eder.
            IsServiceAccount = username is not null
                && username.StartsWith("service-account-", StringComparison.Ordinal)
        };
    }
}
