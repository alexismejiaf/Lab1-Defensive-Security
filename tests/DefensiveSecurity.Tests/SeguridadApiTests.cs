using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading.Tasks;
using NUnit.Framework;

[TestFixture]
[NonParallelizable]
public class SeguridadApiTests
{
    private static readonly HttpClient Api = new(
        new HttpClientHandler { AllowAutoRedirect = false })
    {
        BaseAddress = new Uri("http://127.0.0.1:8081")
    };

    [Test]
    public async Task Hardening_DevuelveLasCabecerasEsperadas()
    {
        using var respuesta = await Api.GetAsync("/");

        Assert.That(respuesta.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(respuesta.Headers.TryGetValues(
            "X-Content-Type-Options", out var valores), Is.True);
        Assert.That(valores, Does.Contain("nosniff"));
        Assert.That(respuesta.Headers.Contains("Server"), Is.False);
        Assert.That(respuesta.Headers.Contains("X-Powered-By"), Is.False);
    }

    [Test]
    public async Task RateLimiting_RechazaLaSextaSolicitud()
    {
        // Deja transcurrir una ventana completa desde las pruebas anteriores.
        await Task.Delay(TimeSpan.FromSeconds(10));

        for (var intento = 1; intento <= 5; intento++)
        {
            using var aceptada = await Api.GetAsync("/");
            Assert.That(aceptada.StatusCode, Is.EqualTo(HttpStatusCode.OK),
                $"La solicitud {intento} debería ser aceptada.");
        }

        using var rechazada = await Api.GetAsync("/");
        Assert.That(rechazada.StatusCode,
            Is.EqualTo(HttpStatusCode.TooManyRequests));
    }

    [Test]
    public async Task JwtBearer_ExigeUnTokenValidoParaConsultarElDocumento()
    {
        const string ruta = "/api/v1/documents/secure/1";
        var token = Environment.GetEnvironmentVariable("TOKEN_CON_PERMISO");

        Assert.That(token, Is.Not.Null.And.Not.Empty,
            "Configura TOKEN_CON_PERMISO con un token vigente de Alice.");

        using var sinToken = await Api.GetAsync(ruta);
        Assert.That(sinToken.StatusCode,
            Is.EqualTo(HttpStatusCode.Unauthorized));

        using var solicitud = new HttpRequestMessage(HttpMethod.Get, ruta);
        solicitud.Headers.Authorization =
            new AuthenticationHeaderValue("Bearer", token);

        using var conToken = await Api.SendAsync(solicitud);
        Assert.That(conToken.StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }
}