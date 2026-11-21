using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace DefensiveSecurity.Api.Controllers;

[ApiController]
[Route("api/v1/documents")]
public class DocumentsController : ControllerBase
{
    private record Document(int Id, string OwnerId, string Title);

    private const string AliceId = "7c1d2a10-3b5e-4f6a-9d11-0a1b2c3d4e01";
    private const string BobId   = "7c1d2a10-3b5e-4f6a-9d11-0a1b2c3d4e02";

    private static readonly List<Document> Documents =
    [
        new(1, AliceId, "Alice's document"),
        new(2, BobId,   "Bob's document"),
    ];

    [HttpGet("secure/{id:int}")]
    [Authorize(Policy = "documents.read")]
    public IActionResult GetSecure(int id)
    {
        var userId = User.FindFirstValue("sub");
        var doc = Documents.FirstOrDefault(d => d.Id == id);

        if (doc is null || doc.OwnerId != userId)
            return NotFound();

        return Ok(doc);
    }
}