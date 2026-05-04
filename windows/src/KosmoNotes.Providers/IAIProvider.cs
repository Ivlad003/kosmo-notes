using KosmoNotes.Core.Models;

namespace KosmoNotes.Providers;

/// <summary>
/// Single-shot (non-streaming) chat completion. Mirrors the Swift
/// <c>AIProvider</c> protocol — streaming is out of scope for v1.0.
/// </summary>
public interface IAIProvider
{
    /// <summary>
    /// Send <paramref name="messages"/> and return the assistant's reply text.
    /// </summary>
    /// <param name="messages">Ordered conversation history (oldest first).</param>
    /// <param name="config">Model + sampling configuration.</param>
    /// <param name="ct">Cancellation token.</param>
    /// <returns>The assistant's text reply.</returns>
    /// <exception cref="AIException">
    /// Thrown for transport, auth, rate-limit, decode, or HTTP failures.
    /// </exception>
    Task<string> ChatAsync(
        IReadOnlyList<ChatMessage> messages,
        AIConfig config,
        CancellationToken ct = default);
}
