using System.Net.Http;

namespace KosmoNotes.Providers.Internal;

/// <summary>
/// Shared default <see cref="HttpClient"/> for providers that don't get one
/// injected. Created lazily and reused for the lifetime of the process —
/// matches Swift's <c>URLSession.shared</c> singleton.
/// </summary>
internal static class HttpDefaults
{
    /// <summary>The lazily-initialised process-wide default client.</summary>
    public static HttpClient Default { get; } = new HttpClient();
}
