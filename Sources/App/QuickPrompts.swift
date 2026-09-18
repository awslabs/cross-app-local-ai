import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "quickprompts")

/// A user-defined prompt shortcut displayed as a chip in the overlay.
struct QuickPrompt: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var prompt: String

    /// - Parameters:
    ///   - name: Display label (max 20 characters for chip UI).
    ///   - prompt: The actual prompt text sent to the LLM.
    init(name: String, prompt: String) {
        self.id = UUID().uuidString
        self.name = name
        self.prompt = prompt
    }
}

/// The collection of quick prompts persisted to `quick_prompts.json`.
struct QuickPrompts: Codable, Equatable {
    var prompts: [QuickPrompt]

    // swiftlint:disable line_length
    /// The default set of prompts seeded on first run.
    static let defaults = QuickPrompts(prompts: [
        QuickPrompt(
            name: "Make professional",
            prompt: "Rewrite the following text in a professional workplace tone. Use clear, direct language appropriate for business communication. Preserve the original meaning and all key information. Do not add new content or remove important details. Return only the rewritten text."
        ),
        QuickPrompt(
            name: "Make coherent",
            prompt: "Rewrite the following text to improve clarity, logical flow, and readability. Fix any disjointed transitions, ambiguous references, or unclear phrasing. Preserve the original meaning, tone, and all key information. Return only the rewritten text."
        ),
        QuickPrompt(
            name: "Make concise",
            prompt: "Rewrite the following text to be as concise as possible without losing any key information. Remove filler words, redundant phrases, and unnecessary qualifiers. Preserve the original meaning and tone. Return only the rewritten text."
        ),
    ])
    // swiftlint:enable line_length

    // MARK: - CRUD

    /// Adds a prompt to the end of the list.
    mutating func add(_ prompt: QuickPrompt) {
        prompts.append(prompt)
    }

    /// Removes the prompt with the given ID.
    ///
    /// - Returns: The removed prompt, or `nil` if no prompt matched.
    @discardableResult
    mutating func remove(id: String) -> QuickPrompt? {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return nil }
        return prompts.remove(at: index)
    }

    /// Returns the prompt with the given ID, if it exists.
    func get(id: String) -> QuickPrompt? {
        prompts.first { $0.id == id }
    }

    /// Updates the name and prompt text of the prompt with the given ID.
    ///
    /// - Returns: `true` if the prompt was found and updated.
    @discardableResult
    mutating func update(id: String, name: String, prompt: String) -> Bool {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return false }
        prompts[index].name = name
        prompts[index].prompt = prompt
        return true
    }

    // MARK: - Persistence

    /// Loads prompts from disk. Returns defaults if the file is missing or corrupt.
    static func load(from path: URL) -> QuickPrompts {
        guard let data = try? Data(contentsOf: path) else {
            logger.info("No quick prompts file, using defaults")
            return .defaults
        }
        do {
            return try sharedJSONDecoder.decode(QuickPrompts.self, from: data)
        } catch {
            logger
                .error(
                    "Failed to decode quick prompts: \(error.localizedDescription, privacy: .public). Using defaults."
                )
            return .defaults
        }
    }

    /// Persists prompts to disk.
    ///
    /// - Parameter path: The file URL to write to.
    /// - Throws: Encoding or file system errors.
    func save(to path: URL) throws {
        let data = try sharedJSONEncoder.encode(self)
        try data.write(to: path, options: .atomic)
    }
}
