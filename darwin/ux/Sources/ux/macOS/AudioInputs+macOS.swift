#if os(macOS)

import AVFoundation
import CoreAudio
import ux_macos_core

/// The audio input devices Core Audio names, and the AUHAL selection that
/// points an `AVAudioEngine` at one of them.
///
/// A device is identified by its Core Audio UID, which survives a reboot and
/// a replug — the numeric `AudioDeviceID` does not. The iOS counterpart is
/// `AudioInputs+iOS.swift`.
enum AudioInputs {
    /// `kAudioObjectPropertyElementMain` under the package's 10.15 floor,
    /// where the symbol itself is unavailable.
    private static let mainElement = AudioObjectPropertyElement(0)

    private struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func list() -> [AudioInput] {
        devices().map { AudioInput(id: $0.uid, label: $0.name) }
    }

    /// Points the engine's input unit at [input]. Voice processing
    /// replaces that unit and keeps the microphone on element 1 (element
    /// 0 is the echo-cancellation output), so this writes that element
    /// when voice processing is on, otherwise the AUHAL current device.
    /// Takes effect while the engine is stopped, and changes the input
    /// node's format.
    static func select(_ input: AudioInput, engine: AVAudioEngine) -> Bool {
        guard let device = devices().first(where: { $0.uid == input.id }),
              let unit = engine.inputNode.audioUnit
        else { return false }
        var id = device.id
        let voiceProcessing = engine.inputNode.isVoiceProcessingEnabled
        let scope: AudioUnitScope = voiceProcessing
            ? kAudioUnitScope_Input
            : kAudioUnitScope_Global
        let element: AudioUnitElement = voiceProcessing ? 1 : 0
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            scope,
            element,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else { return false }
        var current: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            scope,
            element,
            &current,
            &size
        ) == noErr else { return false }
        return current == device.id
    }

    private static func devices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
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
            guard hasInputChannels(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: mainElement
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

    private static func string(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value as String?
    }
}

#endif
