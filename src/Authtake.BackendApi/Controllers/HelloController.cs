using Authtake.BackendApi.Auth;
using Authtake.BackendApi.Extensions;
using Authtake.BackendApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Authtake.BackendApi.Controllers;

[ApiController]
[Route("api/hello")]
[Authorize(Policy = KeycloakAuthenticationExtensions.AuthenticatedPolicy)]
public sealed class HelloController(ILogger<HelloController> logger) : ControllerBase
{
    /// <summary>Gecerli token'i olan her kullanici (admin ve user) erisebilir.</summary>
    [HttpGet("secure")]
    [ProducesResponseType<ApiResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType<ErrorResponse>(StatusCodes.Status401Unauthorized)]
    public ActionResult<ApiResponse> Secure()
    {
        var user = User.ToUserInfo();
        logger.LogInformation("Secure endpoint erisimi: {Username} (client: {ClientId})",
            user.Username, user.ClientId);

        return Ok(new ApiResponse
        {
            Message = $"Hello {user.Name ?? user.Username}, your token is valid.",
            User = user,
            Data = new { endpoint = "/api/hello/secure", requiredRole = (string?)null }
        });
    }
}
