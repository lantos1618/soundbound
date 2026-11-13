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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Soundbound").font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(store.activeRoom == nil ? Color.secondary.opacity(0.4) : quickLiveGreen)
                            .frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(store.activeRoom.map { "In \($0.name)" } ?? "Not in a room")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if store.activeRoom != nil, store.canShareApplicationAudio {
                    RoomAudioShareButton(store: store).buttonStyle(.bordered).controlSize(.small)
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RequestsSection(store: store, mesh: store.mesh)
                    destinationSection
                    applicationsSection
                }.padding(16)
            }.frame(minHeight: 260, idealHeight: 460, maxHeight: 560)
            Divider()
            HStack {
                Button("Open Soundbound", action: openApp).buttonStyle(.plain)
                Spacer()
                Button("Quit", action: quit).buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
        }.frame(width: 380).background(.regularMaterial)
    }
    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
    private func destinationRow(icon: String, name: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder trailing: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(name).lineLimit(1)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let headphone {
                if headphones.count > 1 {
                    Picker("Headphones", selection: $selectedHeadphones) {
                        ForEach(headphones) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                } else {
                    HStack(spacing: 8) {
                        Label(headphone.name, systemImage: "headphones").font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(headphone.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Label(audio.headphoneName, systemImage: "headphones").font(.headline)
                Text("Choose headphones in Soundbound to connect them.").font(.caption).foregroundStyle(.secondary)
            }
            sectionTitle("Listen on").padding(.top, 4)
            destinationRow(icon: "laptopcomputer", name: store.name, selected: headphone?.selectedOutput == true, action: {
                guard let headphone else { return }
                store.recordAudioIntent(.connect, id: headphone.id)
                audio.perform(.connect, id: headphone.id)
            }) {
                if headphone?.selectedOutput == true {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .disabled(headphone == nil || store.activeRoom != nil || audio.busy)
            ForEach(store.friends) { peer in
                let online = store.nearby.contains { $0.id == peer.id }
                destinationRow(icon: peer.card.kind == "mac" ? "laptopcomputer" : "iphone", name: peer.card.name, selected: false, action: {
                    guard let headphone else { return }
                    store.requestDeviceMove(headphone, to: peer.id, from: store.name)
                }) {
                    Text(online ? "Ask to move" : "Offline").font(.caption).foregroundStyle(.secondary)
                    if online { Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary) }
                }
                .disabled(headphone == nil || store.activeRoom != nil || !online)
                .help("Asks that device to take over these headphones. It has to approve.")
            }
            if store.activeRoom != nil, headphone != nil {
                Text("Headphones stay put while this Mac is in a room.").font(.caption).foregroundStyle(.secondary)
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
    private var applicationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Apps playing on this Mac"); Spacer()
                if !mixer.levels.isEmpty { Button("Reset") { mixer.reset() }.font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor) }
            }
            if !mixer.supported { Text("Requires macOS 14.2 or later.").font(.caption).foregroundStyle(.secondary) }
            else if mixer.apps.isEmpty { Text("Apps appear here when they play sound.").font(.caption).foregroundStyle(.secondary) }
            ForEach(mixer.apps) { app in ApplicationVolumeRow(app: app, mixer: mixer) }
            if let error = mixer.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Matches the live colour used in the main window.
private let quickLiveGreen = Color(red: 0.10, green: 0.55, blue: 0.27)

/// Pending approvals. Renders nothing when there is nothing to decide.
private struct RequestsSection: View {
    @ObservedObject var store: HubStore
    @ObservedObject var mesh: AudioMesh
    private var isEmpty: Bool {
        store.deviceMoveRequest == nil && store.requests.isEmpty && store.recordingRequest == nil && mesh.incoming == nil
    }
    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let request = store.deviceMoveRequest {
                    row("Move " + request.deviceName + " here?", detail: "From " + request.senderName,
                        allow: { store.decideDeviceMove(approve: true) }, decline: { store.decideDeviceMove(approve: false) })
                }
                ForEach(store.requests) { request in
                    row(request.roomID == nil ? "Pair with " + request.peer.name + "?" : request.peer.name + " wants to join",
                        detail: request.roomID.flatMap { id in store.rooms.first { $0.id == id }?.name } ?? "Allow this device to connect",
                        allow: { store.decide(request, approve: true) }, decline: { store.decide(request, approve: false) })
                }
                if let request = store.recordingRequest {
                    row("Microphone request", detail: request.senderName + " wants to record this microphone",
                        allow: { store.decideRecordingRequest(allow: true) }, decline: { store.decideRecordingRequest(allow: false) })
                }
                if let request = mesh.incoming {
                    row("Playback request", detail: request.name + " wants to play audio here",
                        allow: { mesh.decide(allow: true) }, decline: { mesh.decide(allow: false) })
                }
            }
        }
    }
    private func row(_ title: String, detail: String, allow: @escaping () -> Void, decline: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Decline", action: decline).buttonStyle(.bordered)
            Button("Allow", action: allow).buttonStyle(.borderedProminent)
        }
        .controlSize(.small).padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
private struct ApplicationVolumeRow: View {
    let app: MixerApp
    @ObservedObject var mixer: AppMixer
    @State private var level = 1.0
    /// Helper processes are shown under the app people recognise.
    private var displayName: String {
        app.name.replacingOccurrences(of: #"\s+Helper(\s*\(.*\))?$"#, with: "", options: .regularExpression)
    }
    var body: some View {
        HStack(spacing: 8) {
            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
            else { Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(.secondary) }
            Text(displayName).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: $level, in: 0...1).onChange(of: level) { mixer.setLevel($0, app: app) }
                .frame(width: 130).accessibilityLabel("Volume for " + displayName)
            Text("\(Int(level * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
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
            Text("\(Int(level * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }.padding(.top, 2).onAppear { level = initialLevel }
    }
}
