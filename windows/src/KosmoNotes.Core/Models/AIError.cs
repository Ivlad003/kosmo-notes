namespace KosmoNotes.Core.Models;

/// <summary>
/// Base class for AI-provider errors. Mirrors the Swift <c>AIError</c> enum cases —
/// each Swift case becomes a sealed subclass here so callers can use C#'s
/// <c>catch</c>-by-type pattern matching naturally.
/// </summary>
public abstract class AIException : Exception
{
    private protected AIException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

/// <summary>The configured endpoint URL is malformed or otherwise unusable.</summary>
public sealed class InvalidEndpointException : AIException
{
    /// <summary>Create a new invalid-endpoint exception.</summary>
    public InvalidEndpointException(Exception? innerException = null)
        : base("Invalid endpoint.", innerException)
    {
    }
}

/// <summary>The API rejected our credentials (HTTP 401).</summary>
public sealed class AuthenticationFailedException : AIException
{
    /// <summary>Create a new authentication-failed exception.</summary>
    public AuthenticationFailedException(Exception? innerException = null)
        : base("Authentication failed.", innerException)
    {
    }
}

/// <summary>The API rate-limited the request (HTTP 429).</summary>
public sealed class RateLimitedException : AIException
{
    /// <summary>Create a new rate-limited exception.</summary>
    public RateLimitedException(Exception? innerException = null)
        : base("Rate limited.", innerException)
    {
    }
}

/// <summary>The send phase failed (transport-level error or non-success status).</summary>
public sealed class SendFailedException : AIException
{
    /// <summary>Create a new send-failed exception with a human-readable message.</summary>
    public SendFailedException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

/// <summary>The response body could not be decoded into the expected shape.</summary>
public sealed class DecodingFailedException : AIException
{
    /// <summary>Create a new decoding-failed exception with a human-readable message.</summary>
    public DecodingFailedException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}
