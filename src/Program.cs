using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

const string ApiRateLimitPolicy = "api";

var builder = WebApplication.CreateBuilder(args);

builder.WebHost.ConfigureKestrel(options => options.AddServerHeader = false);
builder.Services.AddHealthChecks();
builder.Services.AddProblemDetails();
builder.Services.AddControllers();

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.MetadataAddress = builder.Configuration["Authentication:MetadataAddress"];
        options.RequireHttpsMetadata =
            builder.Configuration.GetValue("Authentication:RequireHttpsMetadata", true);
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidIssuer = builder.Configuration["Authentication:Issuer"],
            ValidAudience = builder.Configuration["Authentication:Audience"],
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromSeconds(30)
        };
    });

builder.Services.AddAuthorizationBuilder()
    .AddPolicy("documents.read", policy => policy
        .RequireAuthenticatedUser()
        .RequireAssertion(ctx => HasScope(ctx.User, "documents.read")));

var permitLimit = builder.Configuration.GetValue("RateLimit:PermitLimit", 5);
var windowSeconds = builder.Configuration.GetValue("RateLimit:WindowSeconds", 10);

if (permitLimit < 1 || windowSeconds < 1)
{
    throw new InvalidOperationException("RateLimit:PermitLimit and RateLimit:WindowSeconds must be positive integers.");
}

builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.AddPolicy(ApiRateLimitPolicy, context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = permitLimit,
            Window = TimeSpan.FromSeconds(windowSeconds),
            QueueLimit = 0
        }));
});

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();

app.Use(async (context, next) =>
{
    context.Response.OnStarting(() =>
    {
        context.Response.Headers.XContentTypeOptions = "nosniff";
        return Task.CompletedTask;
    });

    await next(context);
});

app.UseRouting();
app.UseRateLimiter();

app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/", () => TypedResults.Ok(new { service = "defensive-security-api" }))
    .RequireRateLimiting(ApiRateLimitPolicy);
app.MapHealthChecks("/healthz");
app.MapControllers();

app.Run();

static bool HasScope(System.Security.Claims.ClaimsPrincipal user, string scope) =>
    user.FindFirst("scope")?.Value
        .Split(' ', StringSplitOptions.RemoveEmptyEntries)
        .Contains(scope) == true;