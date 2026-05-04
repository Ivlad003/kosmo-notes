using KosmoNotes.Secrets;

namespace KosmoNotes.Secrets.Tests;

public sealed class SecretsKeyTests
{
    [Theory]
    [InlineData(SecretsKey.AnthropicApiKey)]
    [InlineData(SecretsKey.OpenAIApiKey)]
    [InlineData(SecretsKey.OpenRouterApiKey)]
    [InlineData(SecretsKey.OllamaBearerToken)]
    [InlineData(SecretsKey.DeepgramApiKey)]
    [InlineData(SecretsKey.OpenAIEmbeddingApiKey)]
    [InlineData(SecretsKey.AwsAccessKeyId)]
    [InlineData(SecretsKey.AwsSecretAccessKey)]
    public void EveryKey_IsNonEmpty_AndProperlyPrefixed(string key)
    {
        Assert.False(string.IsNullOrWhiteSpace(key));
        Assert.StartsWith("kosmonotes.", key, StringComparison.Ordinal);
    }

    [Fact]
    public void Keys_HaveExpectedExactValues()
    {
        // Exact-value lock so a casual rename triggers a test failure instead of
        // silently invalidating users' existing stored secrets.
        Assert.Equal("kosmonotes.provider.anthropic.api_key", SecretsKey.AnthropicApiKey);
        Assert.Equal("kosmonotes.provider.openai.api_key", SecretsKey.OpenAIApiKey);
        Assert.Equal("kosmonotes.provider.openrouter.api_key", SecretsKey.OpenRouterApiKey);
        Assert.Equal("kosmonotes.provider.ollama.bearer", SecretsKey.OllamaBearerToken);
        Assert.Equal("kosmonotes.transcription.deepgram.api_key", SecretsKey.DeepgramApiKey);
        Assert.Equal("kosmonotes.embeddings.openai.api_key", SecretsKey.OpenAIEmbeddingApiKey);
        Assert.Equal("kosmonotes.sharing.aws.access_key_id", SecretsKey.AwsAccessKeyId);
        Assert.Equal("kosmonotes.sharing.aws.secret_access_key", SecretsKey.AwsSecretAccessKey);
    }
}
