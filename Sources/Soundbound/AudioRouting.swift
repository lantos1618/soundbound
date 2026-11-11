import Foundation

enum AudioDirection { case input, output }

enum RoutingError: LocalizedError {
    case unavailable, rejected(Int32), unconfirmed, volumeUnsupported
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This audio device is no longer available. Reconnect it and try again."
        case .rejected(let status): return "macOS could not change the audio device (\(status))."
        case .unconfirmed: return "macOS did not confirm the change. The previous setting may still be active."
        case .volumeUnsupported: return "This device manages its own volume. Use its volume controls."
        }
    }
}

protocol AudioRoutingBackend {
    func available(_ id: UInt32, direction: AudioDirection) -> Bool
    func current(_ direction: AudioDirection) -> UInt32
    func select(_ id: UInt32, direction: AudioDirection) throws
    func volume(_ id: UInt32) -> Double?
    func setVolume(_ value: Double, id: UInt32) throws
}

/// A successful API call is only a request. Read the hardware state back before
/// reporting success; a device can disappear or refuse a request asynchronously.
struct VerifiedAudioRouting {
    let backend: AudioRoutingBackend
    var attempts = 40
    var pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) }

    func select(_ id: UInt32, direction: AudioDirection) async throws {
        guard backend.available(id, direction: direction) else { throw RoutingError.unavailable }
        try backend.select(id, direction: direction)
        for _ in 0..<attempts {
            try Task.checkCancellation()
            guard backend.available(id, direction: direction) else { throw RoutingError.unavailable }
            if backend.current(direction) == id { return }
            try await pause()
        }
        throw RoutingError.unconfirmed
    }

    func setVolume(_ value: Double, id: UInt32) async throws {
        guard value.isFinite, backend.available(id, direction: .output) else { throw RoutingError.unavailable }
        let level = min(1, max(0, value))
        guard backend.volume(id) != nil else { throw RoutingError.volumeUnsupported }
        try backend.setVolume(level, id: id)
        for _ in 0..<attempts {
            try Task.checkCancellation()
            guard backend.available(id, direction: .output) else { throw RoutingError.unavailable }
            if let actual = backend.volume(id), abs(actual - level) < 0.025 { return }
            try await pause()
        }
        throw RoutingError.unconfirmed
    }
}

import CoreAudio

struct CoreAudioRoutingBackend: AudioRoutingBackend {
    func available(_ id: UInt32, direction: AudioDirection) -> Bool {
        (direction == .output ? Audio.outputs() : Audio.inputs()).contains { $0.id == id }
    }
    func current(_ direction: AudioDirection) -> UInt32 {
        direction == .output ? Audio.current : Audio.currentInput
    }
    func select(_ id: UInt32, direction: AudioDirection) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: direction == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value)
        guard status == noErr else { throw RoutingError.rejected(status) }
    }
    private func volumeElements(_ id: UInt32) -> [UInt32] {
        // Prefer a master control; otherwise use all exposed channel controls.
        func writable(_ channel: UInt32) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(id, &address) &&
                AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
        }
        if writable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        guard channels > 0 else { return [] }
        return (1...channels).filter { writable($0) }
    }
    func volume(_ id: UInt32) -> Double? {
        let elements = volumeElements(id)
        guard !elements.isEmpty else { return nil }
        let values: [Double] = elements.compactMap { channel in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: value))
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
            return Double(value)
        }
        guard values.count == elements.count else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    func setVolume(_ value: Double, id: UInt32) throws {
        let elements = volumeElements(id)
        guard !elements.isEmpty else { throw RoutingError.volumeUnsupported }
        for channel in elements {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
            var level = Float32(value)
            let status = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: level)), &level)
            guard status == noErr else { throw RoutingError.rejected(status) }
        }
    }
}
