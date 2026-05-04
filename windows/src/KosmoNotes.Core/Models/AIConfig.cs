namespace KosmoNotes.Core.Models;

/// <summary>
/// Configuration for a single AI chat call. Mirrors the Swift <c>AIConfig</c> struct.
/// </summary>
/// <param name="Model">Provider-specific model identifier (e.g. <c>claude-sonnet-4-5</c>).</param>
/// <param name="Temperature">Sampling temperature; default 0.7.</param>
/// <param name="MaxTokens">Maximum number of tokens to generate; default 1024.</param>
/// <param name="SystemPrompt">
/// Optional system-role prefix. Routed provider-specifically: Anthropic uses a
/// top-level "system" field; OpenAI prepends a system message.
/// </param>
public sealed record AIConfig(
    string Model,
    double Temperature = 0.7,
    int MaxTokens = 1024,
    string? SystemPrompt = null);
