using Authtake.BackendApi.Auth;
using Authtake.BackendApi.Extensions;
using Authtake.BackendApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Authtake.BackendApi.Controllers;

[ApiController]
[Route("api/admin")]
[Authorize(Policy = KeycloakAuthenticationExtensions.AdminPolicy)]
public sealed class AdminController(ILogger<AdminController> logger) : ControllerBase
{
    /// <summary>
    /// Yalnizca 'admin' realm rolu olan taraflar erisebilir. Buna hem interaktif
    /// login yapan sefo_admin, hem de Client Credentials ile token alan
    /// authtake-3rdparty service account'u dahildir.
    /// </summary>
    [HttpGet("data")]
    [ProducesResponseType<ApiResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType<ErrorResponse>(StatusCodes.Status401Unauthorized)]
    [ProducesResponseType<ErrorResponse>(StatusCodes.Status403Forbidden)]
    public ActionResult<ApiResponse> Data()
    {
        var user = User.ToUserInfo();
        logger.LogInformation("Admin endpoint erisimi: {Username} (serviceAccount: {IsSvc})",
            user.Username, user.IsServiceAccount);

        return Ok(new ApiResponse
        {
            Message = "Admin data retrieved successfully.",
            User = user,
            Data = new
            {
                endpoint = "/api/admin/data",
                requiredRole = "admin",
                accessedVia = user.IsServiceAccount ? "client_credentials" : "authorization_code",
                records = new[]
                {
                    new { id = 1, name = "Confidential Record A", owner = "finance" },
                    new { id = 2, name = "Confidential Record B", owner = "hr" }
                }
            }
        });
    }
}
