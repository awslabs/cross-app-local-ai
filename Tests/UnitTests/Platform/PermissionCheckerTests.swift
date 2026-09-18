import Foundation
import Testing
@testable import FastLang

@Suite("PermissionChecker")
struct PermissionCheckerTests {

    @Test("hasAccessibilityPermission returns a Bool without crashing")
    func accessibilityPermissionSmoke() {
        // We cannot control the actual permission state in tests, but we can
        // verify the call does not crash and returns a valid Bool.
        let result = PermissionChecker.hasAccessibilityPermission
        #expect(result == true || result == false)
    }

    @Test("hasScreenRecordingPermission returns a Bool without crashing")
    func screenRecordingPermissionSmoke() {
        let result = PermissionChecker.hasScreenRecordingPermission
        #expect(result == true || result == false)
    }

    // Microphone permission cannot be smoke-tested in unit tests because
    // AVCaptureDevice.requestAccess(for: .audio) crashes if the host app's
    // Info.plist lacks NSMicrophoneUsageDescription. Covered by integration
    // tests in a properly configured test host.
}
