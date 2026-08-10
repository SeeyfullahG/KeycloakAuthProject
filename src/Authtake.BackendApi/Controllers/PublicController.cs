using Authtake.BackendApi.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Authtake.BackendApi.Controllers;

[ApiController]
[Route("api/public")]
[AllowAnonymous]
public sealed class PublicController : ControllerBase
{
    /// <summary>Token gerektirmez. Her zaman 200 doner.</summary>
    [HttpGet("hello")]
    [ProducesResponseType<ApiResponse>(StatusCodes.Status200OK)]
    public ActionResult<ApiResponse> Hello() => Ok(new ApiResponse
    {
        Message = "Hello from the public endpoint. No authentication required.",
        User = null,
        Data = new { endpoint = "/api/public/hello", requiresAuth = false }
    });
}
