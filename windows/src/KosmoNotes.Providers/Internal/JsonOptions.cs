using System.Text.Json;

namespace KosmoNotes.Providers.Internal;

/// <summary>
/// Shared serializer options for response parsing. Property-name comparison
/// is case-insensitive so providers that return <c>"Choices"</c> instead of
/// <c>"choices"</c> still parse cleanly.
/// </summary>
internal static class JsonOptions
{
    /// <summary>Default lenient deserialization options.</summary>
    public static readonly JsonSerializerOptions Default = new(JsonSerializerDefaults.Web);
}
