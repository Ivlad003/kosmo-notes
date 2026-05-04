namespace KosmoNotes.Core.Models;

/// <summary>
/// A single chat message — a role plus an ordered list of content parts.
/// Mirrors the Swift <c>ChatMessage</c> struct.
/// </summary>
/// <param name="Role">Author of the message.</param>
/// <param name="Parts">Ordered content parts (text and/or images).</param>
public sealed record ChatMessage(ChatRole Role, IReadOnlyList<ChatPart> Parts)
{
    /// <summary>
    /// Convenience factory for a single text-only message.
    /// Mirrors the Swift <c>init(role:content:)</c>.
    /// </summary>
    /// <remarks>
    /// Named <c>FromText</c> rather than <c>Text</c> to avoid shadowing the
    /// instance <see cref="Text"/> property (the C# record promotes the
    /// computed property to a member, which would otherwise collide).
    /// </remarks>
    public static ChatMessage FromText(ChatRole role, string content)
        => new(role, new[] { (ChatPart)new TextPart(content) });

    /// <summary>
    /// Concatenated text content for display and logging; ignores image parts.
    /// Mirrors the Swift <c>text</c> computed property — text parts joined by single spaces.
    /// </summary>
    public string Text => string.Join(" ", Parts.OfType<TextPart>().Select(p => p.Text));

    /// <inheritdoc />
    public bool Equals(ChatMessage? other)
    {
        if (ReferenceEquals(this, other)) return true;
        if (other is null) return false;
        return Role == other.Role && Parts.SequenceEqual(other.Parts);
    }

    /// <inheritdoc />
    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(Role);
        foreach (var part in Parts)
        {
            h.Add(part);
        }
        return h.ToHashCode();
    }
}
