using System.Security.Claims;
using Microsoft.AspNetCore.Components.Authorization;

namespace Authtake.Frontend.Auth;

/// <summary>
/// Statik SSR modunda calisan Razor bilesenlerine oturum bilgisini saglar.
/// Interaktif Blazor (circuit) kullanilsaydi framework bunu kendisi kaydederdi;
/// biz sayfalari sunucuda tek seferde render ettigimiz icin kimligi dogrudan
/// istegin HttpContext'inden okuyoruz. Boylece <see cref="AuthorizeView"/> ve
/// [Authorize] cookie'deki kullaniciyi gorebiliyor.
/// </summary>
public sealed class HttpContextAuthenticationStateProvider(IHttpContextAccessor accessor)
    : AuthenticationStateProvider
{
    private static readonly ClaimsPrincipal Anonymous = new(new ClaimsIdentity());

    public override Task<AuthenticationState> GetAuthenticationStateAsync() =>
        Task.FromResult(new AuthenticationState(accessor.HttpContext?.User ?? Anonymous));
}
