#if os(macOS)

import AVFoundation
import CoreAudio
import XCTest

final class AudioEngineNamedInputTests: XCTestCase {
    func testVoiceProcessingInputElementKeepsTheNamedMicrophoneAndTheOutputDevice() throws {
        let inputs = inputDevices()
        try XCTSkipIf(inputs.isEmpty)
        let engine = AVAudioEngine()
        let node = engine.inputNode
        do {
            try node.setVoiceProcessingEnabled(true)
        } catch {
            throw XCTSkip("voice processing unavailable: \(error)")
        }
        defer { try? node.setVoiceProcessingEnabled(false) }
        let unit = try XCTUnwrap(node.audioUnit)
        let defaultInput = currentDevice(
            unit,
            scope: kAudioUnitScope_Input,
            element: 1
        )
        let target = inputs.first(where: { $0.id != defaultInput }) ?? inputs[0]
        let outputBefore = currentDevice(
            unit,
            scope: kAudioUnitScope_Global,
            element: 0
        )
        var id = target.id
        XCTAssertEqual(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Input,
                1,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            noErr
        )
        XCTAssertEqual(
            currentDevice(unit, scope: kAudioUnitScope_Input, element: 1),
            target.id
        )
        XCTAssertEqual(
            currentDevice(unit, scope: kAudioUnitScope_Global, element: 0),
            outputBefore
        )
    }

    private struct Device {
        let id: AudioDeviceID
    }

    private func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: 0
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard !ids.isEmpty,
              AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            hasInputChannels(id) ? Device(id: id) : nil
        }
    }

    private func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: 0
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return false }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr
        else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func currentDevice(
        _ unit: AudioUnit,
        scope: AudioUnitScope,
        element: AudioUnitElement
    ) -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            scope,
            element,
            &id,
            &size
        )
        return status == noErr ? id : nil
    }
}

#endif
