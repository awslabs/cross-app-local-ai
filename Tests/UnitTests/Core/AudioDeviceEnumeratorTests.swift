import Testing
@testable import FastLang

@Suite("AudioDeviceEnumerator")
struct AudioDeviceEnumeratorTests {

    @Test("enumerates at least one input device on any Mac")
    func findsInputDevices() {
        let devices = AudioDeviceEnumerator.inputDevices()
        #expect(!devices.isEmpty, "Every Mac has at least a built-in microphone")
    }

    @Test("each device has a non-empty name and uid")
    func deviceFieldsPopulated() {
        let devices = AudioDeviceEnumerator.inputDevices()
        for device in devices {
            #expect(!device.name.isEmpty)
            #expect(!device.uid.isEmpty)
            #expect(device.deviceID != 0)
        }
    }

    @Test("built-in microphone sorts first")
    func builtInFirst() {
        let devices = AudioDeviceEnumerator.inputDevices()
        guard let first = devices.first else { return }
        #expect(first.uid.contains("BuiltIn"))
    }

    @Test("default input device returns a valid ID")
    func defaultInputDevice() {
        let deviceID = AudioDeviceEnumerator.defaultInputDeviceID()
        #expect(deviceID != nil)
        if let id = deviceID {
            #expect(id != 0)
        }
    }

    @Test("UID round-trip: enumerate then resolve returns same device ID")
    func uidRoundTrip() {
        let devices = AudioDeviceEnumerator.inputDevices()
        guard let device = devices.first else { return }

        let resolved = AudioDeviceEnumerator.deviceID(forUID: device.uid)
        #expect(resolved == device.deviceID)
    }

    @Test("resolving a bogus UID returns nil")
    func bogusUidReturnsNil() {
        let resolved = AudioDeviceEnumerator.deviceID(forUID: "com.bogus.nonexistent.device.uid")
        #expect(resolved == nil)
    }
}

@Suite("AudioRecorder RMS Energy")
struct AudioRecorderRmsEnergyTests {

    @Test("silence returns zero RMS")
    func silenceIsZero() {
        let rms = Self.computeRms([0, 0, 0, 0, 0, 0, 0, 0])
        #expect(rms == 0)
    }

    @Test("constant signal returns correct RMS")
    func constantSignal() {
        let rms = Self.computeRms([0.5, 0.5, 0.5, 0.5])
        #expect(abs(rms - 0.5) < 0.001)
    }

    @Test("mixed signal returns expected RMS")
    func mixedSignal() {
        let rms = Self.computeRms([1, -1, 1, -1])
        #expect(abs(rms - 1.0) < 0.001)
    }

    @Test("zero frame count returns zero")
    func zeroFrameCount() {
        let samples: [Float] = [1.0]
        let rms = samples.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return Float(0) }
            return AudioRecorder.rmsEnergy(ptr, frameCount: 0)
        }
        #expect(rms == 0)
    }

    @Test("low energy signal is below warmup threshold")
    func lowEnergyBelowThreshold() {
        let rms = Self.computeRms([Float](repeating: 0.001, count: 100))
        #expect(rms < 0.005)
    }

    @Test("speech-level signal is above warmup threshold")
    func speechAboveThreshold() {
        let rms = Self.computeRms([Float](repeating: 0.05, count: 100))
        #expect(rms > 0.005)
    }

    private static func computeRms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return 0 }
            return AudioRecorder.rmsEnergy(ptr, frameCount: samples.count)
        }
    }
}
