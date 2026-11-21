using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

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

app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/", () => TypedResults.Ok(new { service = "defensive-security-api" }));
app.MapHealthChecks("/healthz");
app.MapControllers();

app.Run();

static bool HasScope(System.Security.Claims.ClaimsPrincipal user, string scope) =>
    user.FindFirst("scope")?.Value
        .Split(' ', StringSplitOptions.RemoveEmptyEntries)
        .Contains(scope) == true;