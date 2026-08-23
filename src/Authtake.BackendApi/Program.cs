using System.Net.Mime;
using System.Text.Json.Serialization;
using Authtake.BackendApi.Auth;
using Authtake.BackendApi.Models;
using Microsoft.OpenApi.Models;

var builder = WebApplication.CreateBuilder(args);

const string FrontendCorsPolicy = "AuthtakeFrontend";

builder.Services.AddControllers()
    .AddJsonOptions(o =>
    {
        o.JsonSerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
    });

builder.Services.AddKeycloakJwtAuthentication(builder.Configuration);

builder.Services.AddCors(options =>
    options.AddPolicy(FrontendCorsPolicy, policy => policy
        .WithOrigins(builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [])
        .AllowAnyHeader()
        .AllowAnyMethod()));

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "Authtake Backend API",
        Version = "v1",
        Description = "Keycloak ile korunan resource server. Token'i Keycloak'tan alip "
                    + "Authorize butonuyla yapistirin."
    });

    var scheme = new OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = SecuritySchemeType.Http,
        Scheme = "bearer",
        BearerFormat = "JWT",
        In = ParameterLocation.Header,
        Description = "Keycloak access token (Bearer prefix'i olmadan yapistirin)",
        Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "Bearer" }
    };
    options.AddSecurityDefinition("Bearer", scheme);
    options.AddSecurityRequirement(new OpenApiSecurityRequirement { [scheme] = [] });
});

var app = builder.Build();

// Beklenmeyen hatalar da standart hata zarfiyla donsun. Bu olmadan 500'ler
// bos govdeyle gider ve 401/403 icin tanimladigimiz sozlesmeyi bozar.
// Gelistirmede framework'un ayrintili hata sayfasi zaten once devreye girer;
// bu handler uretimde is gorur.
app.UseExceptionHandler(errorApp => errorApp.Run(async context =>
{
    context.Response.StatusCode = StatusCodes.Status500InternalServerError;
    context.Response.ContentType = MediaTypeNames.Application.Json;

    await context.Response.WriteAsJsonAsync(new ErrorResponse
    {
        Error = "InternalServerError",
        // Ic detay sizdirmiyoruz; ayrinti loglara yazilir.
        Message = "An unexpected error occurred while processing the request.",
        Status = StatusCodes.Status500InternalServerError,
        Path = context.Request.Path.Value
    });
}));

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseCors(FrontendCorsPolicy);
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

app.Run();
