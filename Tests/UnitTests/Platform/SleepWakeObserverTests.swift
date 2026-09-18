import AppKit
import Testing
@testable import FastLang

@Suite("SleepWakeObserver")
struct SleepWakeObserverTests {

    @Test("Calls onSleep when willSleepNotification is posted")
    @MainActor
    func callsOnSleepOnNotification() async {
        var sleepCallCount = 0

        let observer = SleepWakeObserver(
            onSleep: { sleepCallCount += 1 },
            onWake: {}
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        // Yield to let the notification dispatch through the main queue
        await Task.yield()
        await Task.yield()

        #expect(sleepCallCount == 1)
        _ = observer
    }

    @Test("Calls onWake when didWakeNotification is posted")
    @MainActor
    func callsOnWakeOnNotification() async {
        var wakeCallCount = 0

        let observer = SleepWakeObserver(
            onSleep: {},
            onWake: { wakeCallCount += 1 }
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        await Task.yield()
        await Task.yield()

        #expect(wakeCallCount == 1)
        _ = observer
    }

    @Test("Does not call callbacks after deallocation")
    @MainActor
    func noCallbacksAfterDeinit() async {
        var sleepCallCount = 0

        var observer: SleepWakeObserver? = SleepWakeObserver(
            onSleep: { sleepCallCount += 1 },
            onWake: {}
        )
        observer = nil

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        await Task.yield()
        await Task.yield()

        #expect(sleepCallCount == 0)
    }

    @Test("Multiple sleep notifications fire multiple callbacks")
    @MainActor
    func multipleSleepNotifications() async {
        var sleepCallCount = 0

        let observer = SleepWakeObserver(
            onSleep: { sleepCallCount += 1 },
            onWake: {}
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        await Task.yield()
        await Task.yield()
        await Task.yield()

        #expect(sleepCallCount == 2)
        _ = observer
    }
}
