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
        let outputs = route.outputs.map { port in
            LocalAudioDevice(id: port.uid, name: port.portName,
                icon: port.portType == .builtInSpeaker || port.portType == .builtInReceiver ? "speaker.wave.2" : "headphones",
                detail: "This iPhone · Audio output", status: "Current route")
        }
        let inputs = route.inputs.map { port in
            LocalAudioDevice(id: "input:" + port.uid, name: port.portName,
                icon: "mic", detail: "This iPhone · Microphone input", status: "Current route")
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
