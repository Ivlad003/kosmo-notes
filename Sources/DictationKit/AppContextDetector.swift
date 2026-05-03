import AppKit

// MARK: - DictationContext

/// App contexts that influence dictation cleanup LLM formatting hints.
public enum DictationContext: String, Sendable, CaseIterable {
    case cursor
    case vsCode
    case slack
    case discord
    case linear
    case jira
    case notes
    case textEdit
    case `default`

    /// Hint string injected into the LLM cleanup prompt.
    public var contextSpecificFormatting: String {
        switch self {
        case .cursor, .vsCode:
            return "Format as code-friendly: lowercase, snake_case for variables, no trailing punctuation."
        case .slack, .discord:
            return "Conversational, brief, can use Slack-style markdown."
        case .linear, .jira:
            return "Format as a brief task title or comment."
        case .notes, .textEdit, .default:
            return "Standard prose with proper punctuation."
        }
    }
}

// MARK: - AppContextDetector

/// Detects the currently frontmost application and maps it to a DictationContext.
@available(macOS 14.0, *)
public enum AppContextDetector {

    // Bundle ID → DictationContext lookup table
    private static let bundleMap: [String: DictationContext] = [
        "com.todesktop.230313mzl4w4u92": .cursor,
        "com.microsoft.VSCode": .vsCode,
        "com.tinyspeck.slackmacgap": .slack,
        "com.hnc.Discord": .discord,
        "com.linear": .linear,
        "com.atlassian.jira": .jira,
        "com.apple.Notes": .notes,
        "com.apple.TextEdit": .textEdit,
    ]

    /// Returns the DictationContext for the currently frontmost application.
    public static func detect() -> DictationContext {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return .default
        }
        return bundleMap[bundleID] ?? .default
    }
}
