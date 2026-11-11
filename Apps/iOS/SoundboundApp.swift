import SwiftUI
import AVFAudio
import Combine

/// Observe the route without opening a microphone or activating an audio session.
/// iOS audio selection is per app; this does not claim control of other apps.
final class PhoneAudioModel: ObservableObject {
    @Published var devices: [LocalAudioDevice] = []
    private var observer: NSObjectProtocol?
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
        let inputs = route.inputs.map { port -> LocalAudioDevice in
            var device = LocalAudioDevice(id: "input:" + port.uid, name: port.portName,
                icon: "mic", detail: "This iPhone · Microphone input", status: "Current route")
            device.hasInput = true; device.selectedInput = true
            device.connection = port.portType == .builtInMic ? .builtIn : (port.portType == .bluetoothHFP ? .bluetooth : .wired)
            return device
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
            SoundboundRootView(store: store, localAudioDevices: audio.devices)
                .onOpenURL { store.join(codeOrLink: $0.absoluteString) }
        }
    }
}
