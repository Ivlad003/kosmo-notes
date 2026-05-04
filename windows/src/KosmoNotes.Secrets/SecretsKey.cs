namespace KosmoNotes.Secrets;

/// <summary>
/// Canonical key strings for every secret KosmoNotes stores. Centralizing them
/// here prevents drift between the call-sites that read and write the same
/// credential. All keys follow the <c>kosmonotes.&lt;area&gt;.&lt;provider&gt;.&lt;field&gt;</c>
/// convention.
/// </summary>
public static class SecretsKey
{
    /// <summary>API key for Anthropic (Claude) LLM provider.</summary>
    public const string AnthropicApiKey = "kosmonotes.provider.anthropic.api_key";

    /// <summary>API key for OpenAI LLM provider.</summary>
    public const string OpenAIApiKey = "kosmonotes.provider.openai.api_key";

    /// <summary>API key for OpenRouter LLM provider.</summary>
    public const string OpenRouterApiKey = "kosmonotes.provider.openrouter.api_key";

    /// <summary>Optional bearer token for a user-hosted Ollama endpoint.</summary>
    public const string OllamaBearerToken = "kosmonotes.provider.ollama.bearer";

    /// <summary>API key for the Deepgram cloud transcription service.</summary>
    public const string DeepgramApiKey = "kosmonotes.transcription.deepgram.api_key";

    /// <summary>API key for the OpenAI embeddings endpoint.</summary>
    public const string OpenAIEmbeddingApiKey = "kosmonotes.embeddings.openai.api_key";

    /// <summary>AWS / S3-compatible access key id for share-link uploads.</summary>
    public const string AwsAccessKeyId = "kosmonotes.sharing.aws.access_key_id";

    /// <summary>AWS / S3-compatible secret access key for share-link uploads.</summary>
    public const string AwsSecretAccessKey = "kosmonotes.sharing.aws.secret_access_key";
}
