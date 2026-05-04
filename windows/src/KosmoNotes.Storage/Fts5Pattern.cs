using System.Globalization;
using System.Text;

namespace KosmoNotes.Storage;

/// <summary>
/// Mirrors GRDB's <c>FTS5Pattern(matchingAllTokensIn:)</c>. Splits user input
/// on whitespace, escapes embedded double-quotes, wraps each token in
/// <c>"..."</c>, and joins the result with spaces (FTS5 implicit AND).
/// Pure-punctuation tokens are dropped — they have no FTS5 token to match
/// against, and including them would produce no hits.
/// </summary>
internal static class Fts5Pattern
{
    /// <summary>
    /// Build a safe FTS5 pattern from <paramref name="input"/>. Returns
    /// <c>null</c> for empty / whitespace-only / punctuation-only inputs —
    /// callers should treat that as "no results".
    /// </summary>
    public static string? MatchingAllTokensIn(string input)
    {
        if (string.IsNullOrWhiteSpace(input))
        {
            return null;
        }

        string[] rawTokens = input.Split(
            (char[]?)null,
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        var quoted = new List<string>(rawTokens.Length);
        foreach (string token in rawTokens)
        {
            if (!HasAnyLetterOrDigit(token))
            {
                // Pure punctuation contributes nothing to FTS5 matching; mirror
                // the GRDB helper which silently drops these.
                continue;
            }
            string escaped = token.Replace("\"", "\"\"", StringComparison.Ordinal);
            quoted.Add($"\"{escaped}\"");
        }

        if (quoted.Count == 0)
        {
            return null;
        }

        return string.Join(' ', quoted);
    }

    private static bool HasAnyLetterOrDigit(string token)
    {
        foreach (char c in token)
        {
            UnicodeCategory cat = CharUnicodeInfo.GetUnicodeCategory(c);
            switch (cat)
            {
                case UnicodeCategory.UppercaseLetter:
                case UnicodeCategory.LowercaseLetter:
                case UnicodeCategory.TitlecaseLetter:
                case UnicodeCategory.ModifierLetter:
                case UnicodeCategory.OtherLetter:
                case UnicodeCategory.DecimalDigitNumber:
                case UnicodeCategory.LetterNumber:
                case UnicodeCategory.OtherNumber:
                    return true;
            }
        }
        return false;
    }
}
