import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "storage")

/// Resolves and manages on-disk paths for all application data.
///
/// All persistent data lives under `~/Library/Application Support/com.aws.fastlang/`.
/// Use `withRoot(_:)` in tests to redirect to a temporary directory.
struct AppDirs {
    let dataDir: URL

    /// Resolves the standard application support directory.
    ///
    /// - Throws: If `FileManager` cannot locate the application support directory.
    /// - Returns: An `AppDirs` rooted at `~/Library/Application Support/com.aws.fastlang/`.
    static func resolve() throws -> AppDirs {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppDirsError.applicationSupportNotFound
        }
        return AppDirs(dataDir: base.appendingPathComponent("com.aws.fastlang"))
    }

    /// Creates an `AppDirs` rooted at an arbitrary directory for testing.
    static func withRoot(_ root: URL) -> AppDirs {
        AppDirs(dataDir: root)
    }

    // MARK: - Paths

    var modelsDir: URL {
        dataDir.appendingPathComponent("models")
    }

    var settingsPath: URL {
        dataDir.appendingPathComponent("settings.json")
    }

    var appMappingsPath: URL {
        dataDir.appendingPathComponent("app_mappings.json")
    }

    var quickPromptsPath: URL {
        dataDir.appendingPathComponent("prompts/quick_prompts.json")
    }

    var systemPromptsDir: URL {
        dataDir.appendingPathComponent("prompts/system")
    }

    var defaultsDir: URL {
        systemPromptsDir.appendingPathComponent("_defaults")
    }

    var sessionsPath: URL {
        dataDir.appendingPathComponent("history/sessions.json")
    }

    var appRulesPath: URL {
        dataDir.appendingPathComponent("rules/app_rules.json")
    }

    var telemetryDir: URL {
        dataDir.appendingPathComponent("telemetry")
    }

    /// Marker file written by the .pkg installer when the user picked the
    /// E2B model on the installer's model-choice screen.
    ///
    /// On first launch the app reads this marker, sets
    /// `config.llm.localModelId = "gemma-4-e2b"`, removes the marker, and
    /// kicks off the in-app download (with progress bar in Settings).
    /// Markers are one-shot: consumed on read.
    var pkgMarkerE2B: URL {
        dataDir.appendingPathComponent(".download-e2b-on-launch")
    }

    /// Marker file for the E4B model choice. Same mechanism as
    /// `pkgMarkerE2B` but the model ID applied is `gemma-4-e4b`.
    var pkgMarkerE4B: URL {
        dataDir.appendingPathComponent(".download-e4b-on-launch")
    }

    // MARK: - Directory Creation

    /// Creates all required subdirectories if they don't exist.
    ///
    /// - Throws: File system errors from `FileManager.createDirectory`.
    func ensureDirs() throws {
        let fm = FileManager.default
        let dirs = [
            dataDir,
            modelsDir,
            dataDir.appendingPathComponent("prompts"),
            systemPromptsDir,
            defaultsDir,
            dataDir.appendingPathComponent("history"),
            dataDir.appendingPathComponent("rules"),
        ]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        logger.info("Ensured data directories at \(dataDir.path)")
    }
}

/// Errors specific to path resolution.
enum AppDirsError: LocalizedError {
    case applicationSupportNotFound

    var errorDescription: String? {
        switch self {
        case .applicationSupportNotFound:
            "Could not locate the Application Support directory"
        }
    }
}

// MARK: - TempFileGuard

/// RAII guard for safe file downloads.
///
/// Creates a temporary download path (e.g. `model.gguf.downloading`).
/// On `deinit`, the file is automatically removed unless `persist()` has been called.
/// This prevents partial downloads from polluting the file system on crashes or cancellations.
final class TempFileGuard: Sendable {
    let path: URL
    private let _persisted: LockedBool

    /// - Parameter path: The temporary file path to guard.
    init(path: URL) {
        self.path = path
        self._persisted = LockedBool(false)
    }

    /// Marks the file as successfully completed, preventing cleanup on `deinit`.
    func persist() {
        _persisted.set(true)
    }

    /// Whether `persist()` has been called.
    var isPersisted: Bool {
        _persisted.value
    }

    deinit {
        guard !_persisted.value else { return }
        do {
            try FileManager.default.removeItem(at: path)
            // Cannot use logger in deinit of Sendable class safely,
            // but cleanup failure is non-fatal.
        } catch {
            // File may already have been removed or never created -- not an error.
        }
    }
}

/// A simple thread-safe boolean wrapper for use in `Sendable` types.
///
/// Uses `os_unfair_lock` for minimal overhead on single-field synchronization.
final class LockedBool: Sendable {
    private let _lock = OSAllocatedUnfairLock(initialState: false)

    init(_ initial: Bool) {
        _lock.withLock { $0 = initial }
    }

    var value: Bool {
        _lock.withLock { $0 }
    }

    func set(_ newValue: Bool) {
        _lock.withLock { $0 = newValue }
    }
}
