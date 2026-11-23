using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

const string ApiRateLimitPolicy = "api";

var builder = WebApplication.CreateBuilder(args);

builder.WebHost.ConfigureKestrel(options =>
{
    options.AddServerHeader = false;
    options.ConfigureHttpsDefaults(https =>
        https.SslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13);
});
builder.Services.AddHealthChecks();
builder.Services.AddProblemDetails();
builder.Services.AddControllers();

var caPath = builder.Configuration["Authentication:CaCertificatePath"];
var localCa = string.IsNullOrWhiteSpace(caPath) ? null : LoadCertificate(caPath);

var expectedIssuer = builder.Configuration["Authentication:Issuer"];

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.MetadataAddress = builder.Configuration["Authentication:MetadataAddress"];
        options.RequireHttpsMetadata = true;
        options.MapInboundClaims = false;

        if (localCa is not null)
        {
            options.BackchannelHttpHandler = new SocketsHttpHandler
            {
                SslOptions = new SslClientAuthenticationOptions
                {
                    RemoteCertificateValidationCallback =
                        (_, certificate, _, errors) => ValidateWithLocalCa(localCa, certificate, errors)
                }
            };
        }

        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidIssuer = expectedIssuer,
            ValidAudience = builder.Configuration["Authentication:Audience"],
            ValidateIssuer = true,
            IssuerValidator = (issuer, _, _) =>
                string.Equals(issuer, expectedIssuer, StringComparison.Ordinal)
                    ? issuer
                    : throw new SecurityTokenInvalidIssuerException(
                        $"IDX10205: Issuer validation failed. Issuer: '{issuer}'.") { InvalidIssuer = issuer },
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

static X509Certificate2 LoadCertificate(string path)
{
    var pem = File.ReadAllText(path);
    var fields = PemEncoding.Find(pem);
    return X509CertificateLoader.LoadCertificate(Convert.FromBase64String(pem[fields.Base64Data]));
}

// Acepta solo certificados emitidos por la CA local, con nombre válido y uso serverAuth.
static bool ValidateWithLocalCa(X509Certificate2 ca, X509Certificate? certificate, SslPolicyErrors errors)
{
    if (certificate is null) return false;

    // El nombre del host debe coincidir con el SAN.
    if ((errors & (SslPolicyErrors.RemoteCertificateNotAvailable
                   | SslPolicyErrors.RemoteCertificateNameMismatch)) != 0)
        return false;

    using var chain = new X509Chain();
    chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
    chain.ChainPolicy.CustomTrustStore.Add(ca);
    chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
    chain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1"));

    return chain.Build(certificate as X509Certificate2 ?? new X509Certificate2(certificate));
}