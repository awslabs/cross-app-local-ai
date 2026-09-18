import Foundation
import OSLog
import Stencil

private let logger = Logger(subsystem: "com.aws.fastlang", category: "systemprompts")

/// The paste-ready instruction appended to all non-explain system prompts.
private let pasteReadyInstruction = """
CRITICAL: Your output will be pasted directly into the user's document.
Output ONLY the final text, nothing else.
NEVER provide multiple options, alternatives, or numbered choices.
NEVER add explanations, commentary, follow-up questions, or suggestions.
NEVER use labels like 'Option 1' or 'Here is...' or 'Which do you prefer?'.
Produce exactly one piece of text that is ready to paste as-is.
"""

/// Instruction injected into the system prompt when the user is refining a previous output.
private let refinementInstruction = """
You are revising your previous output based on user feedback.
Output ONLY the improved text. Do NOT explain what you changed or why.
Do NOT include reasoning, commentary, or a summary of edits. Return the corrected text, nothing else.
"""

// MARK: - PromptRenderContext

/// Variables passed to the Stencil template engine during rendering.
struct PromptRenderContext {
    var explainMode: Bool
    var mode: PromptMode
    var contextType: ContextType
    var appKey: String
    var appName: String
    var userRules: String
    var inferredPreferences: String
    var refinementFeedback: [String]

    /// Converts to the `[String: Any]` dictionary that Stencil expects.
    func toDictionary() -> [String: Any] {
        let modeInstruction = switch mode {
        case .insert: "Generate new content based on the user's instruction."
        case .replace: "Rewrite or transform the selected text based on the user's instruction."
        }

        return [
            "mode_instruction": modeInstruction,
            "user_rules": userRules,
            "inferred_preferences": inferredPreferences,
            "refinement_feedback": refinementFeedback,
            "refinement_count": refinementFeedback.count,
            "refinement_instruction": refinementFeedback.isEmpty ? "" : refinementInstruction,
            "paste_ready_instruction": explainMode ? "" : pasteReadyInstruction,
            "app_name": appName,
            "app_key": appKey,
            "context_type": contextType.rawValue,
        ]
    }
}

// MARK: - SystemPromptStore

/// Manages system prompt templates on disk and renders them via Stencil.
///
/// On first run, seeds both `systemPromptsDir` (user-editable) and `defaultsDir` (read-only reference).
/// On subsequent runs, re-seeds user templates when the built-in version changes,
/// and always re-seeds `defaultsDir`.
struct SystemPromptStore {

    /// Bump this whenever default templates change to force re-seeding.
    static let templateVersion = 2

    private static let versionFileName = ".template_version"

    private let templates: [String: String]

    /// The loaded template names (without `.md.jinja` extension).
    var templateNames: [String] {
        Array(templates.keys).sorted()
    }

    // MARK: - Initialization

    /// Creates a store by loading templates from disk, seeding defaults if needed.
    ///
    /// - Parameter dirs: The `AppDirs` providing prompt directory paths.
    /// - Throws: File system errors during seeding or reading.
    init(dirs: AppDirs) throws {
        let fm = FileManager.default
        let systemDir = dirs.systemPromptsDir
        let defaultsDir = dirs.defaultsDir

        // Always re-seed _defaults (reference copies)
        try Self.seedTemplates(to: defaultsDir)

        // Re-seed user templates when version is missing or outdated
        let needsSeed = Self.storedVersion(in: systemDir) < Self.templateVersion
        if needsSeed {
            try Self.seedTemplates(to: systemDir)
            try Self.writeVersion(Self.templateVersion, to: systemDir)
            logger.info("Re-seeded templates to version \(Self.templateVersion)")
        }

        // Load all templates from the user-editable directory
        var loaded: [String: String] = [:]
        let files = (try? fm.contentsOfDirectory(atPath: systemDir.path))?.filter {
            $0.hasSuffix(".md.jinja")
        } ?? []
        for file in files {
            let name = String(file.dropLast(".md.jinja".count))
            let filePath = systemDir.appendingPathComponent(file)
            if let content = try? String(contentsOf: filePath, encoding: .utf8) {
                loaded[name] = content
            }
        }
        self.templates = loaded
        logger.info("Loaded \(loaded.count) system prompt template(s)")
    }

    /// Creates a store from a pre-built template dictionary (for testing).
    init(templates: [String: String]) {
        self.templates = templates
    }

    // MARK: - Resolution

    /// Resolves and renders the appropriate template for the given context.
    ///
    /// Resolution order:
    /// 1. If `explainMode` -> use "explain" template
    /// 2. Try `appKey` template (e.g. "slack")
    /// 3. Fall back to `contextType` template (e.g. "chat")
    /// 4. Fall back to "generic"
    ///
    /// - Parameter context: The rendering context with all template variables.
    /// - Returns: The rendered system prompt string.
    /// - Throws: `Stencil.TemplateSyntaxError` if the template has syntax errors.
    func render(context: PromptRenderContext) throws -> String {
        let templateName = resolveTemplateName(context: context)
        guard let templateString = templates[templateName] else {
            logger.warning("Template '\(templateName)' not found, falling back to generic")
            guard let generic = templates["generic"] else {
                return "You are a helpful writing assistant."
            }
            return try renderTemplate(generic, context: context)
        }
        return try renderTemplate(templateString, context: context)
    }

    /// Determines which template name to use based on the context.
    func resolveTemplateName(context: PromptRenderContext) -> String {
        if context.explainMode, templates["explain"] != nil {
            return "explain"
        }
        if templates[context.appKey] != nil {
            return context.appKey
        }
        let contextKey = context.contextType.rawValue.lowercased()
        if templates[contextKey] != nil {
            return contextKey
        }
        return "generic"
    }

    // MARK: - Rendering

    private func renderTemplate(_ templateString: String, context: PromptRenderContext) throws -> String {
        let template = Template(templateString: templateString)
        return try template.render(context.toDictionary())
    }

    // MARK: - Reloading

    /// Re-reads templates from disk. Returns a new store instance.
    ///
    /// - Parameter dirs: The `AppDirs` providing prompt directory paths.
    /// - Returns: A new `SystemPromptStore` with fresh templates.
    /// - Throws: File system errors.
    func reloaded(dirs: AppDirs) throws -> SystemPromptStore {
        try SystemPromptStore(dirs: dirs)
    }

    // MARK: - Seeding

    private static func seedTemplates(to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, content) in defaultTemplates {
            let path = directory.appendingPathComponent("\(name).md.jinja")
            try content.write(to: path, atomically: true, encoding: .utf8)
        }
    }

    /// Reads the stored template version from disk, returning 0 if absent.
    private static func storedVersion(in directory: URL) -> Int {
        let path = directory.appendingPathComponent(versionFileName)
        guard let data = try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let version = Int(data)
        else {
            return 0
        }
        return version
    }

    /// Persists the template version to disk.
    private static func writeVersion(_ version: Int, to directory: URL) throws {
        let path = directory.appendingPathComponent(versionFileName)
        try "\(version)".write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Default Templates

    static let defaultTemplates: [String: String] = [
        "generic": DefaultTemplates.generic,
        "email": DefaultTemplates.email,
        "chat": DefaultTemplates.chat,
        "document": DefaultTemplates.document,
        "spreadsheet": DefaultTemplates.spreadsheet,
        "code": DefaultTemplates.code,
        "notes": DefaultTemplates.notes,
        "slack": DefaultTemplates.slack,
        "outlook": DefaultTemplates.outlook,
        "gmail": DefaultTemplates.gmail,
        "quip": DefaultTemplates.quip,
        "browser": DefaultTemplates.browser,
        "chrome": DefaultTemplates.chrome,
        "word": DefaultTemplates.word,
        "teams": DefaultTemplates.teams,
        "explain": DefaultTemplates.explain,
    ]
}

// MARK: - Default Template Strings

// swiftformat:disable all
private enum DefaultTemplates {
    /// Shared trailer appended to every non-explain template.
    ///
    /// Template structure ends up looking like:
    ///   [role-specific prompt]
    ///   {{ mode_instruction }}
    ///   [preferences]  [user rules]  [refinement feedback+instruction]
    ///   {{ paste_ready_instruction }}
    ///
    /// `paste_ready_instruction` is non-empty only when explain mode is
    /// off (see `PromptRenderContext.toDictionary`). Placing it last so
    /// the LLM weights it heavily relative to the rest of the prompt.
    ///
    /// All templates share this trailer verbatim. If you need to change
    /// instruction ordering, change it here and every template picks it
    /// up through Stencil's string interpolation at seeding time.
    private static let commonTrailer = """
        {{ mode_instruction }}
        {% if inferred_preferences %}
        Observed preferences (background learning from past sessions):
        {{ inferred_preferences }}
        {% endif %}
        {% if user_rules %}
        IMPORTANT — User-defined rules (these ALWAYS take precedence over observed preferences):
        {{ user_rules }}
        {% endif %}
        {% if refinement_count > 0 %}
        Previous feedback from the user:
        {% for feedback in refinement_feedback %}- {{ feedback }}
        {% endfor %}
        {{ refinement_instruction }}
        {% endif %}
        {{ paste_ready_instruction }}
        """

    static let generic = """
        You are a helpful writing assistant. You help users write, edit, and improve text.
        \(commonTrailer)
        """

    static let email = """
        You are a professional email writing assistant.
        You help users compose clear, concise, and well-structured emails.
        \(commonTrailer)
        """

    static let chat = """
        You are a casual messaging assistant.
        You help users write conversational messages that match the tone of the platform.
        Keep messages natural and concise. Avoid overly formal language.
        \(commonTrailer)
        """

    static let document = """
        You are a document writing assistant.
        You help users write clear, well-organized documents with proper structure.
        \(commonTrailer)
        """

    static let spreadsheet = """
        You are a data-oriented writing assistant.
        Keep responses concise and structured for spreadsheet contexts.
        Use short phrases, data labels, and formulas where appropriate.
        \(commonTrailer)
        """

    static let code = """
        You are a technical writing assistant for software development.
        Be precise, use correct terminology, and format code appropriately.
        \(commonTrailer)
        """

    static let notes = """
        You are a note-taking assistant.
        Help users write organized, scannable notes with clear structure.
        Use bullet points, headings, and short paragraphs.
        \(commonTrailer)
        """

    static let slack = """
        You are a Slack messaging assistant.
        Write messages that fit Slack's conversational style.
        Keep messages brief and to the point. Use Slack formatting (bold, code blocks) where appropriate.
        \(commonTrailer)
        """

    static let outlook = """
        You are an Outlook email writing assistant.
        Write professional emails with clear subject context and appropriate sign-offs.
        \(commonTrailer)
        """

    static let gmail = """
        You are a Gmail email writing assistant.
        Write clear, well-structured emails suitable for Gmail's interface.
        \(commonTrailer)
        """

    static let quip = """
        You are a Quip document writing assistant.
        Write well-organized content suitable for collaborative documents.
        \(commonTrailer)
        """

    static let browser = """
        You are a general web content writing assistant.
        Adapt your style to the web context the user is working in.
        \(commonTrailer)
        """

    static let chrome = """
        You are a writing assistant for Google Chrome.
        Adapt your style to the web context the user is working in.
        The user may be composing in web apps, forms, or content editors.
        \(commonTrailer)
        """

    static let word = """
        You are a Microsoft Word document writing assistant.
        Write polished, well-structured content suitable for professional documents.
        Use clear paragraphs, headings where appropriate, and formal tone unless the user specifies otherwise.
        \(commonTrailer)
        """

    static let teams = """
        You are a Microsoft Teams messaging assistant.
        Write messages that fit Teams' professional but conversational style.
        Keep messages clear and actionable. Use Teams formatting where appropriate.
        \(commonTrailer)
        """

    static let explain = """
        You are a helpful explanation assistant.
        The user has highlighted some text and wants you to explain it.
        Provide a clear, concise explanation of the highlighted text.
        Use simple language. If the text is code, explain what it does.
        If the text is jargon, define the terms.
        Do NOT rewrite the text. Explain it.
        {% if user_rules %}
        User-defined rules:
        {{ user_rules }}
        {% endif %}
        """
}
// swiftformat:enable all
