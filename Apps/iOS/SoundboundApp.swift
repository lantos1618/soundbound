import SwiftUI
import AVFAudio
import Combine

/// Observe the route without opening a microphone or activating an audio session.
/// iOS audio selection is per app; this does not claim control of other apps.
final class PhoneAudioModel: ObservableObject {
    @Published var devices: [LocalAudioDevice] = []
    private var observer: NSObjectProtocol?
    private var refreshTimer: Timer?
    private let testPlayback = MeshAudioIO()
    private let testTone = MeshAudioIO()
    private let testDelivery = PCMDelivery()
    private var testGeneration = UUID()
    @Published var message: String?
    var onTestStarted: ((String) -> Void)?
    var onTestStopped: ((String) -> Void)?
    private var testOutputID: String?
    var onTestFrame: ((String, Data) -> Void)?
    var playbackGain: ((String) -> Double)?
    func setPlaybackGain(_ id: String, level: Double) {
        if testOutputID == id { testDelivery.setGain(level) }
    }
    func perform(_ action: LocalAudioAction, id: String) {
        if case .stopTest = action { stopTest(); return }
        let repeating: Bool
        switch action {
        case .testOutput: repeating = true
        case .testOutputOnce: repeating = false
        default: return
        }
        guard devices.contains(where: { $0.id == id && $0.hasOutput && $0.selectedOutput }) else { return }
        do {
            stopTest()
            let generation = UUID(); testGeneration = generation
            try testPlayback.startPlayback(expectedOutputID: id)
            testOutputID = id
            if let sink = testPlayback.playbackSink() {
                testDelivery.configure(routes: [.init(send: sink)], gain: playbackGain?(id) ?? 1)
            }
            testDelivery.updates.start { [weak self] _, pcm in if let pcm { self?.onTestFrame?(id, pcm) } }
            testTone.startTestTone(repeating: repeating) { [delivery = testDelivery] in delivery.submit($0) }
            onTestStarted?(id)
            message = "Playing test sound"
            if !repeating { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.testGeneration == generation else { return }
                self.stopTest()
            } }
        } catch { message = error.localizedDescription }
    }
    private func stopTest() {
        testDelivery.stop(); testGeneration = UUID(); testTone.stop(); testPlayback.stop(); message = nil
        if let id = testOutputID { onTestStopped?(id); testOutputID = nil }
    }
    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { refreshTimer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs.map { port -> LocalAudioDevice in
            let builtIn = port.portType == .builtInSpeaker || port.portType == .builtInReceiver
            var device = LocalAudioDevice(id: builtIn ? AudioDeviceInventory.phoneSpeakerID : port.uid, name: builtIn ? UIDevice.current.name + " Speaker" : port.portName,
                icon: builtIn ? "speaker.wave.2" : "headphones",
                detail: "This iPhone · Audio output", status: "Current route")
            device.hasOutput = true; device.selectedOutput = true
            if builtIn { device.legacyID = port.uid }
            if MeshAudioIO.audioSessionIsActive {
                let playback = AudioPlaybackMetrics.snapshot(id: device.id)
                device.latency = AudioDeviceLatency(outputMilliseconds: session.outputLatency * 1_000,
                    ioBufferMilliseconds: session.ioBufferDuration > 0 ? session.ioBufferDuration * 1_000 : nil,
                    playbackBufferMilliseconds: playback?.queuedMilliseconds,
                    playbackTargetMilliseconds: playback?.targetMilliseconds, playbackRecoveries: playback?.recoveries)
            }
            device.connection = builtIn ? .builtIn : ([.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(port.portType) ? .bluetooth : .wired)
            if device.connection == .bluetooth { device.physicalID = "ios-port:" + port.uid }
            return device
        }
        var inputs = route.inputs.map { port -> LocalAudioDevice in
            var device = LocalAudioDevice(id: port.portType == .builtInMic ? "builtin-microphone" : "input:" + port.uid, name: port.portName,
                icon: "mic", detail: "This iPhone · Microphone input", status: "Current route")
            device.hasInput = true; device.selectedInput = true
            if MeshAudioIO.audioSessionIsActive { device.latency = AudioDeviceLatency(inputMilliseconds: session.inputLatency * 1_000) }
            device.connection = port.portType == .builtInMic ? .builtIn : (port.portType == .bluetoothHFP ? .bluetooth : .wired)
            if device.connection == .bluetooth { device.physicalID = "ios-port:" + port.uid }
            return device
        }
        if inputs.isEmpty {
            var microphone = LocalAudioDevice(id: "builtin-microphone", name: UIDevice.current.name + " Microphone", icon: "mic", detail: "This iPhone · Microphone input", status: "Double-tap to record")
            microphone.hasInput = true; microphone.connection = .builtIn
            inputs.append(microphone)
        }
        devices = AudioDeviceInventory.phoneInventory(outputs + inputs, name: UIDevice.current.name)
    }
}

@main
struct SoundboundMobileApp: App {
    @StateObject private var store = HubStore()
    @StateObject private var audio = PhoneAudioModel()
    var body: some Scene {
        WindowGroup {
            SoundboundRootView(store: store, localAudioDevices: audio.devices, audioMessage: audio.message, onAudioAction: { audio.perform($0, id: $1) })
                .onAppear { audio.playbackGain = { store.audioGain(for: $0) }; store.onPlaybackGainChanged = { audio.setPlaybackGain($0, level: $1) }; audio.onTestStarted = { store.activity.chirp($0); store.activity.chirp(store.deviceID) }; audio.onTestStopped = { store.activity.clear($0); store.activity.clear(store.deviceID) }; audio.onTestFrame = { store.activity.updateLevel($0, pcm: $1) } }
                .onOpenURL { url in
                    if url.host != "auth" { store.join(codeOrLink: url.absoluteString) }
                }
        }
    }
}
