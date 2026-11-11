import SwiftUI
import AVFAudio
import Combine

/// Observe the route without opening a microphone or activating an audio session.
/// iOS audio selection is per app; this does not claim control of other apps.
final class PhoneAudioModel: ObservableObject {
    @Published var devices: [LocalAudioDevice] = []
    private var observer: NSObjectProtocol?
    private let testPlayback = MeshAudioIO()
    private let testTone = MeshAudioIO()
    private var testGeneration = UUID()
    @Published var message: String?
    var onTestStarted: ((String) -> Void)?
    var onTestFrame: ((String, Data) -> Void)?
    func perform(_ action: LocalAudioAction, id: String) {
        if case .stopTest = action { testGeneration = UUID(); testTone.stop(); testPlayback.stop(); return }
        guard case .testOutput = action, devices.contains(where: { $0.id == id && $0.hasOutput && $0.selectedOutput }) else { return }
        do {
            let generation = UUID(); testGeneration = generation
            try testPlayback.startPlayback(expectedOutputID: id)
            testTone.startTestTone { [weak self] pcm in self?.testPlayback.play(pcm); self?.onTestFrame?(id, pcm) }
            onTestStarted?(id)
            message = "Playing test sound"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.testGeneration == generation else { return }
                self.testTone.stop(); self.testPlayback.stop(); self.message = nil
            }
        } catch { message = error.localizedDescription }
    }
    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() {
        let route = AVAudioSession.sharedInstance().currentRoute
        let outputs = route.outputs.map { port -> LocalAudioDevice in
            let builtIn = port.portType == .builtInSpeaker || port.portType == .builtInReceiver
            var device = LocalAudioDevice(id: port.uid, name: builtIn ? UIDevice.current.name + " Speaker" : port.portName,
                icon: builtIn ? "speaker.wave.2" : "headphones",
                detail: "This iPhone · Audio output", status: "Current route")
            device.hasOutput = true; device.selectedOutput = true
            device.connection = builtIn ? .builtIn : ([.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(port.portType) ? .bluetooth : .wired)
            return device
        }
        var inputs = route.inputs.map { port -> LocalAudioDevice in
            var device = LocalAudioDevice(id: port.portType == .builtInMic ? "builtin-microphone" : "input:" + port.uid, name: port.portName,
                icon: "mic", detail: "This iPhone · Microphone input", status: "Current route")
            device.hasInput = true; device.selectedInput = true
            device.connection = port.portType == .builtInMic ? .builtIn : (port.portType == .bluetoothHFP ? .bluetooth : .wired)
            return device
        }
        if inputs.isEmpty {
            var microphone = LocalAudioDevice(id: "builtin-microphone", name: UIDevice.current.name + " Microphone", icon: "mic", detail: "This iPhone · Microphone input", status: "Hold to record")
            microphone.hasInput = true; microphone.connection = .builtIn
            inputs.append(microphone)
        }
        devices = outputs + inputs
    }
}

@main
struct SoundboundMobileApp: App {
    @StateObject private var store = HubStore()
    @StateObject private var audio = PhoneAudioModel()
    var body: some Scene {
        WindowGroup {
            SoundboundRootView(store: store, localAudioDevices: audio.devices, audioMessage: audio.message, onAudioAction: { audio.perform($0, id: $1) })
                .onAppear { audio.onTestStarted = { store.activity.chirp($0); store.activity.chirp(store.deviceID) }; audio.onTestFrame = { store.activity.updateLevel($0, pcm: $1) } }
                .onOpenURL { url in
                    if url.host != "auth" { store.join(codeOrLink: url.absoluteString) }
                }
        }
    }
}
