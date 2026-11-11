import AppKit
import SwiftUI
import SoundboundKit

struct QuickControls: View {
    @ObservedObject var store: HubStore
    @ObservedObject var audio: SoundModel
    @ObservedObject var mixer: AppMixer
    var openApp: () -> Void
    var quit: () -> Void
    @State private var selectedHeadphones = ""
    private var headphones: [LocalAudioDevice] { AudioDeviceInventory.headphones(in: audio.localAudioDevices) }
    private var headphone: LocalAudioDevice? { headphones.first { $0.id == selectedHeadphones } ?? headphones.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Soundbound").font(.headline)
                Spacer()
                Button(action: openApp) { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Open Soundbound")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    destinationSection
                    applicationsSection
                    notificationsSection
                }.padding(16)
            }.frame(maxHeight: 580)
            Divider()
            HStack {
                Button("Open Soundbound", action: openApp).buttonStyle(.plain)
                Spacer()
                Button("Quit", action: quit).buttonStyle(.plain)
            }.font(.caption).padding(16)
        }.frame(width: 360).background(.regularMaterial)
    }
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let headphone {
                if headphones.count > 1 {
                    Picker("Headphones", selection: $selectedHeadphones) {
                        ForEach(headphones) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                } else { Label(headphone.name, systemImage: "headphones").font(.headline) }
            } else {
                Label(audio.headphoneName, systemImage: "headphones").font(.headline)
                Text("Choose headphones in Soundbound to connect them.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Listen on").font(.caption).foregroundStyle(.secondary)
            Button {
                guard let headphone else { return }
                store.recordAudioIntent(.connect, id: headphone.id)
                audio.perform(.connect, id: headphone.id)
            } label: {
                HStack {
                    Label(store.name, systemImage: "laptopcomputer")
                    Spacer()
                    if headphone?.selectedOutput == true { Image(systemName: "checkmark") }
                }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .disabled(headphone == nil || store.activeRoom != nil || audio.busy)
            ForEach(store.friends) { peer in
                Button {
                    guard let headphone else { return }
                    store.requestDeviceMove(headphone, to: peer.id, from: store.name)
                } label: {
                    HStack {
                        Label(peer.card.name, systemImage: peer.card.kind == "mac" ? "laptopcomputer" : "iphone")
                        Spacer()
                        if !store.nearby.contains(where: { $0.id == peer.id }) { Text("Offline").font(.caption).foregroundStyle(.secondary) }
                        else { Image(systemName: "arrow.right") }
                    }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(headphone == nil || store.activeRoom != nil || !store.nearby.contains { $0.id == peer.id })
            }
            if let headphone, let level = headphone.volume { HardwareVolumeRow(device: headphone, initialLevel: level, audio: audio) }
            if let move = store.outgoingDeviceMove {
                HStack(alignment: .top) {
                    Label(move.message, systemImage: move.phase == .connected ? "checkmark.circle" : "arrow.left.arrow.right")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { store.dismissDeviceMoveStatus() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss move status")
                }
            }
        }
        .onAppear { if selectedHeadphones.isEmpty { selectedHeadphones = headphones.first?.id ?? "" } }
    }
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notifications").font(.subheadline.weight(.semibold))
            if let request = store.deviceMoveRequest {
                requestRow("Move " + request.deviceName + " here?", detail: "From " + request.senderName,
                           allow: { store.decideDeviceMove(approve: true) }, decline: { store.decideDeviceMove(approve: false) })
            }
            ForEach(store.requests) { request in
                requestRow(request.roomID == nil ? "Pair with " + request.peer.name + "?" : request.peer.name + " wants to join",
                           detail: request.roomID.flatMap { id in store.rooms.first { $0.id == id }?.name } ?? "Allow this device to connect",
                           allow: { store.decide(request, approve: true) }, decline: { store.decide(request, approve: false) })
            }
            if let request = store.recordingRequest {
                requestRow("Microphone request", detail: request.senderName + " wants to record this microphone",
                           allow: { store.decideRecordingRequest(allow: true) }, decline: { store.decideRecordingRequest(allow: false) })
            }
            PlaybackRequests(mesh: store.mesh, hasOtherRequests: store.deviceMoveRequest != nil || !store.requests.isEmpty || store.recordingRequest != nil)
        }
    }
    private func requestRow(_ title: String, detail: String, allow: @escaping () -> Void, decline: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Allow", action: allow).buttonStyle(.borderedProminent)
                Button("Decline", action: decline).buttonStyle(.bordered)
            }.controlSize(.small)
        }
    }
    private var applicationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Applications on this Mac").font(.subheadline.weight(.semibold)); Spacer()
                if !mixer.levels.isEmpty { Button("Reset") { mixer.reset() }.font(.caption).buttonStyle(.plain) }
            }
            if !mixer.supported { Text("Requires macOS 14.2 or later.").font(.caption).foregroundStyle(.secondary) }
            else if mixer.apps.isEmpty { Text("Apps appear here when they play sound.").font(.caption).foregroundStyle(.secondary) }
            ForEach(mixer.apps) { app in ApplicationVolumeRow(app: app, mixer: mixer) }
            if let error = mixer.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
private struct PlaybackRequests: View {
    @ObservedObject var mesh: AudioMesh
    var hasOtherRequests: Bool
    var body: some View {
        if let request = mesh.incoming {
            VStack(alignment: .leading, spacing: 6) {
                Text("Playback request").font(.subheadline.weight(.medium))
                Text(request.name + " wants to play audio here").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Allow") { mesh.decide(allow: true) }.buttonStyle(.borderedProminent)
                    Button("Decline") { mesh.decide(allow: false) }.buttonStyle(.bordered)
                }.controlSize(.small)
            }
        } else if !hasOtherRequests {
            Text("No requests.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
private struct ApplicationVolumeRow: View {
    let app: MixerApp
    @ObservedObject var mixer: AppMixer
    @State private var level = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                Text(app.name).lineLimit(1)
                Spacer()
                Text("\(Int(level * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $level, in: 0...1).onChange(of: level) { mixer.setLevel($0, app: app) }
                .accessibilityLabel("Volume for " + app.name)
        }
        .onAppear { level = mixer.levels[app.id] ?? 1 }
        .onChange(of: mixer.levels[app.id]) { level = $0 ?? 1 }
    }
}
private struct HardwareVolumeRow: View {
    let device: LocalAudioDevice
    let initialLevel: Double
    @ObservedObject var audio: SoundModel
    @State private var level = 0.5
    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
            Slider(value: $level, in: 0...1).onChange(of: level) { audio.setVolume(device.id, level: $0) }
            Text("\(Int(level * 100))%").font(.caption).monospacedDigit().frame(width: 32)
        }.onAppear { level = initialLevel }
    }
}
