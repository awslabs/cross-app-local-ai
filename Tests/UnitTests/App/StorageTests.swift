import Foundation
import Testing
@testable import FastLang

@Suite("AppDirs")
struct AppDirsTests {

    @Test("resolve returns path under Application Support")
    func resolvePath() throws {
        let dirs = try AppDirs.resolve()
        #expect(dirs.dataDir.path.contains("Application Support"))
        #expect(dirs.dataDir.lastPathComponent == "com.aws.fastlang")
    }

    @Test("withRoot uses the provided directory")
    func withRoot() {
        let root = URL(fileURLWithPath: "/tmp/test-fastlang")
        let dirs = AppDirs.withRoot(root)
        #expect(dirs.dataDir == root)
    }

    @Test("computed paths are under dataDir")
    func computedPaths() {
        let root = URL(fileURLWithPath: "/tmp/test-fastlang")
        let dirs = AppDirs.withRoot(root)
        #expect(dirs.settingsPath.path.hasPrefix(root.path))
        #expect(dirs.appMappingsPath.path.hasPrefix(root.path))
        #expect(dirs.quickPromptsPath.path.hasPrefix(root.path))
        #expect(dirs.systemPromptsDir.path.hasPrefix(root.path))
        #expect(dirs.defaultsDir.path.hasPrefix(root.path))
        #expect(dirs.sessionsPath.path.hasPrefix(root.path))
        #expect(dirs.appRulesPath.path.hasPrefix(root.path))
    }

    @Test("settingsPath ends with settings.json")
    func settingsPathFilename() {
        let dirs = AppDirs.withRoot(URL(fileURLWithPath: "/tmp/qg"))
        #expect(dirs.settingsPath.lastPathComponent == "settings.json")
    }

    @Test("defaultsDir is under systemPromptsDir")
    func defaultsUnderSystem() {
        let dirs = AppDirs.withRoot(URL(fileURLWithPath: "/tmp/qg"))
        #expect(dirs.defaultsDir.path.hasPrefix(dirs.systemPromptsDir.path))
        #expect(dirs.defaultsDir.lastPathComponent == "_defaults")
    }

    @Test("ensureDirs creates all required directories")
    func ensureDirsCreates() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dirs = AppDirs.withRoot(tmpDir)
        try dirs.ensureDirs()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: tmpDir.path))
        #expect(fm.fileExists(atPath: dirs.systemPromptsDir.path))
        #expect(fm.fileExists(atPath: dirs.defaultsDir.path))

        let historyDir = tmpDir.appendingPathComponent("history")
        #expect(fm.fileExists(atPath: historyDir.path))

        let rulesDir = tmpDir.appendingPathComponent("rules")
        #expect(fm.fileExists(atPath: rulesDir.path))
    }

    @Test("ensureDirs is idempotent")
    func ensureDirsIdempotent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dirs = AppDirs.withRoot(tmpDir)
        try dirs.ensureDirs()
        try dirs.ensureDirs()
        #expect(FileManager.default.fileExists(atPath: tmpDir.path))
    }
}

@Suite("TempFileGuard")
struct TempFileGuardTests {

    @Test("removes file on deinit when not persisted")
    func removesOnDeinit() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let filePath = tmpDir.appendingPathComponent("model.gguf.downloading")
        try Data("test".utf8).write(to: filePath)
        #expect(FileManager.default.fileExists(atPath: filePath.path))

        var tempGuard: TempFileGuard? = TempFileGuard(path: filePath)
        _ = tempGuard // suppress unused warning
        tempGuard = nil // triggers deinit

        #expect(!FileManager.default.fileExists(atPath: filePath.path))
    }

    @Test("persist prevents removal on deinit")
    func persistPreventsRemoval() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let filePath = tmpDir.appendingPathComponent("model.gguf.downloading")
        try Data("test".utf8).write(to: filePath)

        var tempGuard: TempFileGuard? = TempFileGuard(path: filePath)
        tempGuard?.persist()
        #expect(tempGuard?.isPersisted == true)
        tempGuard = nil

        #expect(FileManager.default.fileExists(atPath: filePath.path))
    }

    @Test("deinit with nonexistent file does not throw")
    func nonexistentFileOk() {
        let fakePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nonexistent.tmp")
        var tempGuard: TempFileGuard? = TempFileGuard(path: fakePath)
        _ = tempGuard
        tempGuard = nil // should not crash
    }
}
