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
    /// Korumali veri. Iki rolden birine sahip olanlar erisebilir:
    /// 'admin' (interaktif login yapan gercek kullanici, orn. sefo_admin) veya
    /// 'service-api' (Client Credentials ile token alan servis hesabi).
    /// Insan ve makine yetkileri bilerek ayri rollerde tutulur.
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
                requiredRoles = new[] { "admin", "service-api" },
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
