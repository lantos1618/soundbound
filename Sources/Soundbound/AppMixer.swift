import AppKit
import CoreAudio
import Combine
import os

struct MixerApp: Identifiable {
    var id: String
    var name: String
    var processes: [AudioObjectID]
    var icon: NSImage?
}

final class AppMixer: ObservableObject {
    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var levels: [String: Double] = [:]
    @Published var error: String?
    private var sessions: [String: AnyObject] = [:]
    private var timer: Timer?
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }
    var supported: Bool { if #available(macOS 14.2, *) { return true }; return false }
    func refresh() {
        guard #available(macOS 14.2, *) else { return }
        let running = NSWorkspace.shared.runningApplications
        var grouped: [String: MixerApp] = [:]
        for id in MixerHAL.list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard MixerHAL.number(id, kAudioProcessPropertyIsRunningOutput) != 0 else { continue }
            let pid = pid_t(MixerHAL.number(id, kAudioProcessPropertyPID))
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let process = NSRunningApplication(processIdentifier: pid)
            let bundle = MixerHAL.string(id, kAudioProcessPropertyBundleID) ?? "pid:\(pid)"
            let owner = running.first { app in
                if let root = app.bundleURL?.path, let path = process?.executableURL?.path { return path.hasPrefix(root + "/") }
                return app.bundleIdentifier == bundle
            } ?? process
            let key = owner?.bundleIdentifier ?? bundle
            guard key != Bundle.main.bundleIdentifier else { continue }
            if grouped[key] == nil { grouped[key] = MixerApp(id: key, name: owner?.localizedName ?? bundle, processes: [], icon: owner?.icon) }
            grouped[key]?.processes.append(id)
        }
        apps = grouped.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for key in Array(sessions.keys) {
            guard let app = grouped[key], let session = sessions[key] as? AppTapSession else {
                (sessions.removeValue(forKey: key) as? AppTapSession)?.stop(); levels[key] = nil; continue
            }
            if Set(session.processes) != Set(app.processes) || session.outputID != MixerHAL.number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) {
                setLevel(levels[key] ?? 1, app: app)
            }
        }
    }
    func setLevel(_ level: Double, app: MixerApp) {
        guard #available(macOS 14.2, *) else { return }
        let value = min(1, max(0, level))
        if value < 0.999, let existing = sessions[app.id] as? AppTapSession,
           Set(existing.processes) == Set(app.processes), existing.outputID == MixerHAL.number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) {
            existing.setGain(Float(value)); levels[app.id] = value; return
        }
        (sessions.removeValue(forKey: app.id) as? AppTapSession)?.stop()
        if value > 0.999 { levels[app.id] = 1; return }
        do {
            let session = try AppTapSession(processes: app.processes, gain: Float(value))
            sessions[app.id] = session
            levels[app.id] = value
            error = nil
        } catch {
            levels[app.id] = 1
            self.error = "Could not change \(app.name): \(error.localizedDescription)"
        }
    }
    func reset() {
        if #available(macOS 14.2, *) { for session in sessions.values { (session as? AppTapSession)?.stop() } }
        sessions.removeAll(); levels.removeAll(); error = nil
    }
}

private enum MixerHAL {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector), value: CFString? = nil, size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }
    static func list(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !values.isEmpty, AudioObjectGetPropertyData(id, &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }
}

@available(macOS 14.2, *)
private final class AppTapSession {
    let processes: [AudioObjectID]
    let outputID: AudioObjectID
    private let gainState: OSAllocatedUnfairLock<Float>
    func setGain(_ gain: Float) { gainState.withLock { $0 = gain } }
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    init(processes: [AudioObjectID], gain: Float) throws {
        self.processes = processes
        gainState = OSAllocatedUnfairLock(initialState: gain)
        outputID = MixerHAL.number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        do {
            guard let outputUID = MixerHAL.string(outputID, kAudioDevicePropertyDeviceUID) else { throw MixerError.output }
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "Soundbound app mixer"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tap))
            var format = AudioStreamBasicDescription(), address = MixerHAL.address(kAudioTapPropertyFormat)
            var size = UInt32(MemoryLayout.size(ofValue: format))
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { throw MixerError.format }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Soundbound app mixer",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate))
            var outputFormat = AudioStreamBasicDescription()
            var outputAddress = MixerHAL.address(kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput)
            var outputSize = UInt32(MemoryLayout.size(ofValue: outputFormat))
            try check(AudioObjectGetPropertyData(aggregate, &outputAddress, 0, nil, &outputSize, &outputFormat))
            guard outputFormat.mFormatID == kAudioFormatLinearPCM, outputFormat.mBitsPerChannel == 32,
                  outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  abs(outputFormat.mSampleRate - format.mSampleRate) < 1 else { throw MixerError.format }
            let gainState = self.gainState
            var previousGain = gain
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil) { _, input, _, output, _ in
                let currentGain = gainState.withLockIfAvailable { $0 } ?? previousGain
                previousGain = currentGain
                let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let outputs = UnsafeMutableAudioBufferListPointer(output)
                var channelOffset = 0
                for out in outputs {
                    guard let raw = out.mData, out.mNumberChannels > 0 else { continue }
                    let destination = raw.assumingMemoryBound(to: Float.self)
                    let frames = Int(out.mDataByteSize) / MemoryLayout<Float>.size / Int(out.mNumberChannels)
                    for frame in 0..<frames {
                        for channel in 0..<Int(out.mNumberChannels) {
                            var offset = channelOffset + channel
                            var sample: Float = 0
                            for source in inputs {
                                let channels = Int(source.mNumberChannels)
                                if offset < channels, channels > 0, let data = source.mData,
                                   frame < Int(source.mDataByteSize) / MemoryLayout<Float>.size / channels {
                                    sample = data.assumingMemoryBound(to: Float.self)[frame * channels + offset]
                                    break
                                }
                                offset -= channels
                            }
                            destination[frame * Int(out.mNumberChannels) + channel] = sample * currentGain
                        }
                    }
                    channelOffset += Int(out.mNumberChannels)
                }
            })
            try check(AudioDeviceStart(aggregate, io))
        } catch { stop(); throw error }
    }
    deinit { stop() }
    func stop() {
        if aggregate != 0, let io { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io) }
        io = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    private func check(_ status: OSStatus) throws { if status != noErr { throw MixerError.status(status) } }
}
private enum MixerError: LocalizedError {
    case output, format, status(OSStatus)
    var errorDescription: String? {
        switch self {
        case .output: return "No playback device is available."
        case .format: return "This playback format is not supported."
        case .status(let code): return "macOS rejected the audio setup (\(code)). Check Soundbound’s System Audio Recording permission."
        }
    }
}
