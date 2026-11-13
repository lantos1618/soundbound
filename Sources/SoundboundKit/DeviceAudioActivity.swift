import Foundation
import Combine

struct DevicePlaybackSnapshot: Codable, Equatable {
    var id: String
    var level: Double
    var roomID: String? = nil
    /// How loud each pitch band is, low to high, for the frequency view. Absent from older builds.
    var bands: [Double]? = nil
}

/// What the meters draw: loudness over time, or how loud each pitch is right now.
public enum MeterVisualisation: String, Codable, CaseIterable, Identifiable {
    case amplitude, frequency
    public var id: String { rawValue }
    public var title: String { self == .amplitude ? "Amplitude" : "Frequency" }
}

/// Preferences that follow the person across their own devices.
struct SharedSettings: Codable, Equatable {
    var visualisation: String
    var changed: Date
}

public final class DeviceAudioActivity: ObservableObject {
    public enum Mode: Equatable { case idle, waiting, chirping, recording }
    @Published public private(set) var modes: [String: Mode] = [:]
    @Published public private(set) var levels: [String: Double] = [:]
    @Published public private(set) var message: String?
    @Published public private(set) var messageID: String?
    @Published public private(set) var recordedID: String?
    @Published public private(set) var waveforms: [String: [Double]] = [:]
    /// Loudness of each pitch band, low to high, per device.
    @Published public private(set) var spectra: [String: [Double]] = [:]
    @Published public private(set) var visualisation = MeterVisualisation(rawValue: UserDefaults.standard.string(forKey: "Soundbound.visualisation") ?? "") ?? .amplitude
    private(set) var visualisationChanged = UserDefaults.standard.object(forKey: "Soundbound.visualisationChanged") as? Date ?? .distantPast
    public static let bandCount = 24
    public static let amplitudeBarCount = 32
    private var recentSamples: [String: [Float]] = [:]
    private var lastSpectrum: [String: Date] = [:]
    public func setVisualisation(_ value: MeterVisualisation, changed: Date = Date()) {
        visualisation = value; visualisationChanged = changed
        UserDefaults.standard.set(value.rawValue, forKey: "Soundbound.visualisation")
        UserDefaults.standard.set(changed, forKey: "Soundbound.visualisationChanged")
    }
    var sharedSettings: SharedSettings { SharedSettings(visualisation: visualisation.rawValue, changed: visualisationChanged) }
    /// Takes a setting from another of this person's devices when it was changed more recently than ours.
    func adopt(_ settings: SharedSettings, now: Date = Date()) {
        guard settings.changed > visualisationChanged, settings.changed < now.addingTimeInterval(60),
              let value = MeterVisualisation(rawValue: settings.visualisation) else { return }
        setVisualisation(value, changed: settings.changed)
    }
    /// The bars a meter should draw for a device, in the chosen view.
    public func bars(_ id: String) -> [Double] { (visualisation == .frequency ? spectra[id] : waveforms[id]) ?? [] }
    /// A host meter follows its loudest active component, including recordings.
    func meterID(host: String, components: [String]) -> String {
        let active = ([host] + components).filter { (modes[$0] ?? .idle) != .idle }
        let recording = active.filter { modes[$0] == .recording }
        return (recording.isEmpty ? active : recording)
            .max { (levels[$0] ?? 0) < (levels[$1] ?? 0) } ?? host
    }
    private var clip = Data()
    private let io = MeshAudioIO()
    private var generation = UUID()
    private var remoteCaptureID: String?
    private var captureID: String?
    private var held = false
    private var playbackTimer: DispatchSourceTimer?
    private var lastLevelUpdate: [String: Date] = [:]
    var stopStream: (() -> Void)?
    var inputGain: ((String) -> Double)?
    var playbackGain: (() -> Double)?
    public init() {}
    /// The amplitude meter is a strip chart: every 40 ms each meter gains one bar for the loudness of the sound
    /// that arrived in that time (or an empty bar if none did) and the oldest bar drops off the other end. Sound
    /// only adds to the current bar; the clock moves the chart. So the chart scrolls at the same speed whatever the
    /// packet size, keeps scrolling through pauses, and the screen is redrawn 25 times a second rather than once a packet.
    static let meterWindowSamples = 960
    private var windowEnergy: [String: Double] = [:], windowCount: [String: Int] = [:]
    private var peerLevels: [String: (level: Double, at: Date)] = [:]
    private var meterClock: Timer?
    public func updateLevel(_ id: String, pcm: Data) {
        lastLevelUpdate[id] = Date()
        updateSpectrum(id, pcm: pcm)
        var energy = windowEnergy[id] ?? 0
        pcm.withUnsafeBytes { bytes in
            for i in stride(from: 0, to: pcm.count - 1, by: 2) {
                let sample = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32768
                energy += sample * sample
            }
        }
        windowEnergy[id] = energy; windowCount[id, default: 0] += pcm.count / 2
        startMeterClock()
    }
    private func startMeterClock() {
        guard meterClock == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.tickMeters() }
        RunLoop.main.add(timer, forMode: .common)
        meterClock = timer
    }
    /// One step of the strip chart for every meter. Called by the clock; tests call it directly.
    func tickMeters(now: Date = Date()) {
        var next = waveforms
        for id in Set(next.keys).union(windowCount.keys).union(peerLevels.keys) {
            var value = 0.0
            if let count = windowCount[id], count > 0 {
                value = min(1, sqrt((windowEnergy[id] ?? 0) / Double(count)) * 5)
                windowEnergy[id] = 0; windowCount[id] = 0
                levels[id] = value
            } else if let peer = peerLevels[id], now.timeIntervalSince(peer.at) < 1.5 {
                value = peer.level
            }
            let history = Array(((next[id] ?? []) + [value]).suffix(Self.amplitudeBarCount))
            if history.allSatisfy({ $0 == 0 }), (modes[id] ?? .idle) == .idle {
                next[id] = nil; windowEnergy[id] = nil; windowCount[id] = nil; peerLevels[id] = nil
            } else { next[id] = history }
        }
        if next != waveforms { waveforms = next }
        if next.isEmpty, windowCount.isEmpty, peerLevels.isEmpty { meterClock?.invalidate(); meterClock = nil }
    }
    /// Bar heights from 0 to 1, as every meter in the app and on the map draws them. Loudness uses a decibel scale,
    /// so quiet sound is still visible and loud sound still has room to move. Frequency bands are shown against
    /// the loudest band.
    public func barHeights(_ id: String) -> [Double] {
        let samples = bars(id)
        if visualisation == .frequency {
            let peak = max(0.04, samples.max() ?? 0)
            return samples.map { sqrt(max(0, min(1, $0 / peak))) }
        }
        return samples.map { $0 <= 0 ? 0 : max(0, min(1, (20 * log10(max($0 / 5, 0.000_01)) + 54) / 40)) }
    }
    /// Keeps the last 512 samples (about 21 ms) and, about fifteen times a second, measures 24 pitch bands in them.
    private func updateSpectrum(_ id: String, pcm: Data) {
        var samples = recentSamples[id] ?? []
        pcm.withUnsafeBytes { bytes in
            for i in stride(from: max(0, pcm.count - 1024), to: pcm.count - 1, by: 2) {
                samples.append(Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32768)
            }
        }
        if samples.count > 512 { samples.removeFirst(samples.count - 512) }
        recentSamples[id] = samples
        let now = Date()
        guard samples.count >= 256, now.timeIntervalSince(lastSpectrum[id] ?? .distantPast) > 0.066 else { return }
        lastSpectrum[id] = now
        spectra[id] = Self.bands(samples)
    }
    /// 24 bands spaced evenly by pitch from 80 Hz to 10 kHz, each 0–1.
    static func bands(_ samples: [Float], sampleRate: Double = 24_000) -> [Double] {
        let count = samples.count
        guard count > 0 else { return [] }
        return (0..<bandCount).map { band in
            let frequency = 80 * pow(10_000 / 80, Double(band) / Double(bandCount - 1))
            let coefficient = Float(2 * cos(2 * Double.pi * frequency / sampleRate))
            var first: Float = 0, second: Float = 0
            for sample in samples { let next = sample + coefficient * first - second; second = first; first = next }
            let power = max(0, first * first + second * second - coefficient * first * second)
            let magnitude = Double(power.squareRoot()) / (Double(count) / 2)
            return min(1, magnitude.squareRoot() * 1.8)
        }
    }
    public func showRecordingHint(_ id: String) {
        messageID = id
        message = "Double-tap the microphone icon to record. Double-tap again to stop, then choose Replay."
    }
    public func waiting(_ id: String) { modes[id] = .waiting }
    public func clearWaiting() {
        for id in Array(modes.keys) where modes[id] == .waiting { modes[id] = nil }
    }
    public func chirp(_ id: String) {
        modes[id] = .chirping; levels[id] = 0
    }
    public func beginRecording(_ device: LocalAudioDevice) {
        guard device.hasInput, device.isAvailable, captureID == nil else { return }
        playbackTimer?.cancel(); playbackTimer = nil
        if let old = recordedID { modes[old] = nil; levels[old] = nil }
        let token = UUID(); generation = token; captureID = device.id; held = true
        clip = Data(); recordedID = nil; messageID = device.id; modes[device.id] = .waiting; message = "Waiting for microphone permission…"
        MeshAudioIO.microphonePermission { [weak self] allowed in
            guard let self, self.generation == token, self.held else { return }
            guard allowed else { self.message = "Allow microphone access in Settings to record."; self.endRecording(device.id); return }
            do {
                try self.io.startCapture(inputSystemID: device.systemInputID, inputUID: device.id.hasPrefix("input:") ? String(device.id.dropFirst(6)) : device.id) { [weak self] data in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token, self.held else { return }
                        let adjusted = AudioGain.applying(self.inputGain?(device.id) ?? 1, to: data)
                        if self.clip.count + adjusted.count <= 1_440_000 { self.clip.append(adjusted) }
                        self.updateLevel(device.id, pcm: adjusted)
                    }
                }
                self.modes[device.id] = .recording
                self.message = "Recording \(device.name) — tap to stop."
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard self?.generation == token else { return }; self?.endRecording(device.id)
                }
            } catch { self.message = error.localizedDescription; self.endRecording(device.id) }
        }
    }
    public func endRecording(_ id: String) {
        guard captureID == id else { if modes[id] == .recording || modes[id] == .waiting { stopStream?() }; return }
        held = false; generation = UUID(); captureID = nil; io.stop()
        modes[id] = nil; levels[id] = nil
        if !clip.isEmpty { recordedID = id; message = "Recording ready. It stays on this device in memory." }
        else if message == "Waiting for microphone permission…" { message = "Tap the microphone again to record." }
    }
    public func playRecording(_ id: String) {
        guard recordedID == id, !clip.isEmpty, captureID == nil else { return }
        playbackTimer?.cancel()
        do { try io.startPlayback() } catch { message = error.localizedDescription; return }
        let data = clip, token = UUID(); generation = token
        var offset = 0
        modes[id] = .chirping; message = "Playing your recording here."
        let timer = DispatchSource.makeTimerSource(queue: .main); playbackTimer = timer
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if offset >= data.count {
                timer.cancel(); self.playbackTimer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard self.generation == token else { return }
                    self.io.stop(); self.modes[id] = nil; self.levels[id] = nil
                }
                return
            }
            let frame = Data(data[offset..<min(offset + 960, data.count)])
            let adjusted = AudioGain.applying(self.playbackGain?() ?? 1, to: frame)
            self.io.play(adjusted); self.updateLevel(id, pcm: adjusted); offset += frame.count
        }
        timer.resume()
    }
    public func clearStreams() {
        for id in Array(modes.keys) where id != captureID { clear(id) }
    }
    public func clear(_ id: String) {
        // The chart is left to scroll out by itself, so a stream that restarts does not wipe what was just shown.
        modes[id] = nil; levels[id] = nil; lastLevelUpdate[id] = nil
        spectra[id] = nil; recentSamples[id] = nil; lastSpectrum[id] = nil; windowEnergy[id] = nil; windowCount[id] = nil; peerLevels[id] = nil
    }
    /// Export measured playback only, never microphone levels or mirrored peers.
    func playbackSnapshot(ids: Set<String>, now: Date = Date()) -> [DevicePlaybackSnapshot] {
        ids.sorted().compactMap { id in
            guard modes[id] == .chirping, let updated = lastLevelUpdate[id],
                  now.timeIntervalSince(updated) < 2 else { return nil }
            return DevicePlaybackSnapshot(id: id, level: levels[id] ?? 0, bands: spectra[id]?.map { ($0 * 100).rounded() / 100 })
        }
    }
    func showPeerPlayback(_ id: String, level: Double, bands: [Double]? = nil) {
        modes[id] = .chirping; levels[id] = level
        if let bands, bands.count == Self.bandCount, bands.allSatisfy({ $0.isFinite && (0...1).contains($0) }) { spectra[id] = bands }
        peerLevels[id] = (level, Date()); startMeterClock()
    }
    public func beginRemoteRecording(_ id: String) {
        stopRecording(); stopPlayback(); remoteCaptureID = id
        clip = Data(); recordedID = nil; modes[id] = .waiting
    }
    public func receiveRemoteFrame(_ pcm: Data) {
        guard let id = remoteCaptureID else { return }
        if clip.count + pcm.count <= 1_440_000 { clip.append(pcm) }
        modes[id] = .recording; updateLevel(id, pcm: pcm)
    }
    public func finishRemoteRecording() {
        guard let id = remoteCaptureID else { return }
        remoteCaptureID = nil; clear(id)
        if !clip.isEmpty { recordedID = id }
    }
    public func showStreamLevel(_ id: String, pcm: Data, recording: Bool) {
        modes[id] = recording ? .recording : .chirping; updateLevel(id, pcm: pcm)
    }
    public func stopPlayback() {
        guard captureID == nil else { return }
        generation = UUID(); playbackTimer?.cancel(); playbackTimer = nil; io.stop()
        if let id = recordedID { modes[id] = nil; levels[id] = nil }
        message = "Playback stopped."
    }
    public func stopRecording() { if let captureID { endRecording(captureID) } }
    private static func level(_ data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        var sum = 0.0
        data.withUnsafeBytes { bytes in
            for i in stride(from: 0, to: data.count - 1, by: 2) {
                let sample = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32768
                sum += sample * sample
            }
        }
        return min(1, sqrt(sum / Double(data.count / 2)) * 5)
    }
}
