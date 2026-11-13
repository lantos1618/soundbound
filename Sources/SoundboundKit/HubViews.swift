import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AuthenticationServices
import UniformTypeIdentifiers
#if os(iOS)
import MediaPlayer
#endif

public struct SoundboundRootView: View {
    @ObservedObject var store: HubStore
    let localAudioDevices: [LocalAudioDevice]
    let audioMessage: String?
    let onAudioAction: (LocalAudioAction, String) -> Void
    let onAudioVolume: (String, Double) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    @State private var choosingOutput = false
    @State private var showingAudioMap = false
    public init(store: HubStore, localAudioDevices: [LocalAudioDevice] = [], audioMessage: String? = nil,
                onAudioAction: @escaping (LocalAudioAction, String) -> Void = { _, _ in },
                onAudioVolume: @escaping (String, Double) -> Void = { _, _ in }) {
        self.store = store; self.localAudioDevices = AudioDeviceInventory.reconcile(localAudioDevices); self.audioMessage = audioMessage
        self.onAudioAction = { action, id in
            store.recordAudioIntent(action, id: id)
            if !store.handleRoomAudioAction(action, id: id) { onAudioAction(action, id) }
        }
        self.onAudioVolume = onAudioVolume
    }
    public var body: some View {
        NavigationStack {
            Group {
                // The audio map is a place in this window, not a sheet over it.
                if showingAudioMap && store.developerMode {
                    AudioMapPane(store: store).background(canvasColor)
                } else {
                    HomeView(store: store, localAudioDevices: localAudioDevices, audioMessage: audioMessage,
                             onAudioAction: onAudioAction, onAudioVolume: onAudioVolume)
                }
            }
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Soundbound")
                                .font(.shared(.title2, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            HStack(spacing: 6) {
                                Circle().fill(store.activeRoom == nil ? Color.secondary.opacity(0.4) : liveGreen)
                                    .frame(width: 7, height: 7).accessibilityHidden(true)
                                Text(store.activeRoom.map { "In \($0.name)" } ?? "Not in a room")
                                    .font(.shared(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if store.developerMode {
                            Button { showingAudioMap.toggle() } label: {
                                Label(showingAudioMap ? "Devices" : "Audio map",
                                      systemImage: showingAudioMap ? "list.bullet" : "point.3.connected.trianglepath.dotted")
                            }.buttonStyle(PillButtonStyle())
                                .accessibilityLabel(showingAudioMap ? "Back to rooms and devices" : "Show the audio map")
                        }
                        Button { settings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                    }
                    .padding(.horizontal, pageMargin)
                    .frame(maxWidth: 850)
                    .frame(maxWidth: .infinity)
                    .padding(.top, headerTopInset)
                    .padding(.bottom, 10)
                    .background(canvasColor)
                }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 590)
        #endif
        .sheet(isPresented: $settings) {
            NavigationStack {
                SettingsView(store: store)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
            }
            #if os(macOS)
            .frame(width: 580, height: 640)
            #endif
        }
        .onAppear {
            store.observeAudioDevices(localAudioDevices)
            #if os(iOS)
            PlaybackRequestNotifications.shared.attach(to: store.mesh)
            #endif
            store.onApprovedDeviceMove = { name in
                #if os(iOS)
                choosingOutput = true
                #else
                if let device = store.reportedAudioDevices.first(where: { $0.canMoveBetweenHosts && $0.name == name }) {
                    onAudioAction(.connect, device.id)
                } else {
                    store.notice = "Pair \(name) with this Mac in Bluetooth settings first."
                }
                #endif
            }
        }
        .sheet(isPresented: $choosingOutput) {
            VStack(spacing: 20) {
                Text("Choose your headphones").font(.shared(.headline))
                Text("Use Apple’s audio picker below to connect them to this iPhone.")
                    .multilineTextAlignment(.center)
                #if os(iOS)
                PhoneOutputPicker().frame(height: 44)
                #endif
                Button("Done") { choosingOutput = false }
            }.padding(28)
        }
        .alert("Move headphones?", isPresented: Binding(get: { store.deviceMoveRequest != nil }, set: { _ in })) {
            Button("Allow") { store.decideDeviceMove(approve: true) }
            Button("Decline", role: .cancel) { store.decideDeviceMove(approve: false) }
        } message: {
            if let request = store.deviceMoveRequest {
                Text("\(request.senderName) is asking to use \(request.deviceName) on \(store.name).")
            }
        }
        .alert("Allow microphone recording?", isPresented: Binding(get: { store.recordingRequest != nil }, set: { _ in })) {
            Button("Allow recording") { store.decideRecordingRequest(allow: true) }
            Button("Decline", role: .cancel) { store.decideRecordingRequest(allow: false) }
        } message: {
            Text("\(store.recordingRequest?.senderName ?? "A paired device") wants to record this microphone. Audio is encrypted and either device can stop.")
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { store.activity.stopRecording() }
            if phase == .active { AppleAccount.shared.refreshCredential() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            store.observeAudioDevices(localAudioDevices, now: date)
        }
        .overlay { IncomingAudioApproval(mesh: store.mesh) }
        .overlay(alignment: .bottom) {
            if let notice = store.audioNotice {
                Text(notice).font(.shared(.subheadline)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(16)
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if !Task.isCancelled, store.audioNotice == notice { store.audioNotice = nil }
                    }
            }
        }
        .alert("Soundbound", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }
}

#if os(iOS)
private struct PhoneOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let picker = MPVolumeView(frame: .zero)
        picker.showsVolumeSlider = false
        picker.showsRouteButton = true
        return picker
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif

private struct IncomingAudioApproval: View {
    @ObservedObject var mesh: AudioMesh
    var body: some View {
        if let request = mesh.incoming {
            ZStack {
                Color.black.opacity(0.2).ignoresSafeArea().onTapGesture {}
                VStack(spacing: 16) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 30)).foregroundStyle(.green)
                    Text("Allow audio playback?").font(.shared(.headline))
                    Text("\(request.name) wants to play on \(request.outputName ?? "this device").")
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Decline") { mesh.decide(allow: false) }.buttonStyle(.bordered)
                        Button("Allow audio") { mesh.decide(allow: true) }.buttonStyle(.borderedProminent)
                    }
                }.padding(24).frame(maxWidth: 350)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .padding(24)
            }
        }
    }
}

private struct HomeAudioStatus: View {
    @ObservedObject var store: HubStore
    @ObservedObject var mesh: AudioMesh
    @ObservedObject var roomAudio: RoomAudio
    @ObservedObject var activity: DeviceAudioActivity
    @ObservedObject var roomTest: RoomPlaybackTest
    let localMessage: String?
    let stopRoom: () -> Void
    private var recording: Bool { activity.modes.values.contains(.recording) }
    private var replaying: Bool { activity.recordedID.map { activity.modes[$0] == .chirping } ?? false }
    private var busy: Bool { recording || replaying || mesh.active || roomAudio.active || roomAudio.receiving || roomTest.active }
    private var message: String {
        if roomAudio.active { return roomAudio.status }
        if roomAudio.receiving { return roomAudio.receivingStatus }
        if recording || replaying { return activity.message ?? "Audio active" }
        if mesh.active { return mesh.status }
        if roomTest.active { return roomTest.status }
        if let localMessage { return localMessage }
        if let message = activity.message { return message }
        // Leftover lines such as "Audio stopped" say nothing the screen does not already show.
        return ""
    }
    var body: some View {
        if busy || !message.isEmpty { bar }
    }
    private var bar: some View {
        HStack(spacing: 12) {
            if busy { Circle().fill(liveGreen).frame(width: 7, height: 7).accessibilityHidden(true) }
            Text(message).font(.shared(.subheadline)).foregroundStyle(busy ? .primary : .secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop") {
                if roomAudio.active || roomAudio.receiving { stopRoom() }
                else if recording { activity.stopRecording() }
                else if replaying { activity.stopPlayback() }
                else if roomTest.active { roomTest.stop() }
                else { mesh.stop() }
            }.buttonStyle(.bordered).controlSize(.small).opacity(busy ? 1 : 0)
                .disabled(!busy).accessibilityHidden(!busy)
        }
        .padding(.horizontal, pageMargin).frame(maxWidth: 850).frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

public struct RoomAudioShareButton: View {
    @ObservedObject private var store: HubStore
    @ObservedObject private var audio: RoomAudio
    public init(store: HubStore) { self.store = store; self.audio = store.roomAudio }
    public var body: some View {
        Button(audio.sharingApplications ? "Stop sharing Mac audio" : "Share Mac audio") {
            store.shareApplicationAudioWithRoom()
        }
    }
}

private struct AudioDeviceGlyph: View {
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    let symbol: String
    let name: String
    var input: LocalAudioDevice? = nil
    var inputAction: (() -> Void)? = nil
    var enabled = true
    var muted = false
    var toggleMute: (() -> Void)? = nil
    var canTest = true
    /// For a microphone on another device: a double tap starts or stops recording it.
    var recordOnDoubleTap = false
    let play: () -> Void
    private var mode: DeviceAudioActivity.Mode { activity.modes[id] ?? .idle }
    private var color: Color { mode == .recording ? .red : mode == .chirping ? .green : mode == .waiting ? .orange : .secondary }
    private func legacyAction() {
        if let input {
            if let inputAction { inputAction() }
            else if mode == .recording || mode == .waiting { activity.endRecording(id) }
            else { activity.beginRecording(input) }
        } else { play() }
    }
    var body: some View {
        ZStack {
            Circle().fill(mode == .idle ? Color.primary.opacity(0.05) : color.opacity(0.14))
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(muted ? Color.secondary.opacity(0.4) : color)
            if muted { Image(systemName: "slash.circle.fill").font(.system(size: 13)).foregroundStyle(.red).offset(x: 13, y: 13) }
        }.frame(width: 40, height: 40).contentShape(Circle())
        .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { gesture in
            guard enabled || mode != .idle else { return }
            switch gesture {
            case .first:
                // A double tap records a microphone and stops it again; on a speaker it plays or stops the test sound.
                // Nothing here needs a press-and-hold, which would fight with dragging the row.
                if let input {
                    if mode == .recording || mode == .waiting { activity.endRecording(id) } else { activity.beginRecording(input) }
                } else if canTest || recordOnDoubleTap { play() }
            case .second: if let toggleMute { toggleMute() } else { legacyAction() }
            }
        })
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(name + (toggleMute == nil ? "" : muted ? ", muted" : ", unmuted"))
        .accessibilityAction { if let toggleMute { toggleMute() } else { legacyAction() } }
        .accessibilityAction(named: "Play or stop test sound") { if canTest && enabled { play() } }
        .accessibilityAction(named: "Start or stop recording") {
            if let input { if mode == .recording || mode == .waiting { activity.endRecording(id) } else { activity.beginRecording(input) } }
            else if recordOnDoubleTap { play() }
        }
        .help(toggleMute == nil ? "Play or stop a test sound" : canTest ? "Click to mute/unmute. Double-click to play/stop test audio." : "Click to mute/unmute. Double-click to start or stop recording.")
    }
}

private struct DeviceWaveform: View {
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    var componentIDs: [String] = []
    /// Narrow layouts use a wide, shallow strip under the name instead of a small block beside it.
    var strip = false
    var body: some View {
        let displayedID = activity.meterID(host: id, components: componentIDs)
        let mode = activity.modes[displayedID] ?? .idle
        // Capture published values in the view, so Canvas invalidates when PCM arrives.
        let frequency = activity.visualisation == .frequency
        let samples = activity.barHeights(displayedID)
        Canvas { context, size in
            let color: Color = mode == .recording ? .red : mode == .chirping ? .green : mode == .waiting ? .orange : .secondary.opacity(0.25)
            // Amplitude scrolls through time; frequency is one bar per pitch band, low on the left, rising from the bottom.
            let count = frequency ? DeviceAudioActivity.bandCount : DeviceAudioActivity.amplitudeBarCount
            let step = size.width / Double(count)
            for index in 0..<count {
                let sampleIndex = index - (count - samples.count)
                let sample = mode == .idle || sampleIndex < 0 || sampleIndex >= samples.count ? 0 : samples[sampleIndex]
                // A perceptual scale keeps quiet, audible signals visible.
                let height = max(2, sample * (size.height - 2))
                let rect = CGRect(x: Double(index) * step, y: frequency ? size.height - height : (size.height - height) / 2, width: max(1, step * (frequency ? 0.6 : 0.45)), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }.frame(maxWidth: strip ? .infinity : 220).frame(height: strip ? 30 : 24)
        .accessibilityLabel((mode == .recording ? "Recording" : mode == .chirping ? "Playback" : "Audio") + (activity.visualisation == .frequency ? " frequencies" : " level"))

    }
}

private struct RoomHeading<Actions: View>: View {
    let name: String
    let subtitle: String
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    let componentIDs: [String]
    @ViewBuilder var actions: () -> Actions
    @Environment(\.stackedLevels) private var stackedLevels

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.shared(.title3, weight: .semibold)).lineLimit(1)
            Text(subtitle).font(.shared(.caption)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var meter: some View {
        DeviceWaveform(activity: activity, id: id, componentIDs: componentIDs).frame(width: 84)
    }
    var body: some View {
        if stackedLevels {
            // Name and actions share one line; the meter gets the full width beneath them.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    title
                    HStack(spacing: 6) { actions() }.fixedSize(horizontal: true, vertical: false)
                }
                DeviceWaveform(activity: activity, id: id, componentIDs: componentIDs, strip: true)
            }
        } else {
            HStack(spacing: 8) {
                HStack(spacing: 12) {
                    title
                    meter
                }.frame(maxWidth: .infinity).layoutPriority(1)
                HStack(spacing: 8) { actions() }
                    .frame(width: 328, alignment: .trailing)
            }
        }
    }
}

private struct AudioStateLabel: View {
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    let fallback: String
    var body: some View {
        let mode = activity.modes[id] ?? .idle
        Text(mode == .recording ? "Recording" : mode == .chirping ? "Playing" : mode == .waiting ? "Waiting for reply" : fallback)
            .font(.shared(.caption)).foregroundStyle(mode == .recording ? Color.red : mode == .chirping ? .green : mode == .waiting ? .orange : .secondary)
    }
}

private struct RecordingReplayControl: View {
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    private var available: Bool { activity.recordedID == id }
    var body: some View {
        if available {
            Button("Replay") { activity.playRecording(id) }
                .font(.shared(.caption)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }
    }
}

private struct DeviceRowText: View {
    let name: String
    let detail: String
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    let status: String
    var canReplay = false
    var prominent = false
    /// True when the detail line already says what the status would, so the status shows only while audio is active.
    var statusInDetail = false
    @Environment(\.stackedLevels) private var stackedLevels
    private var showsStatus: Bool { !statusInDetail || hasActivity }
    private var hasActivity: Bool { (activity.modes[id] ?? .idle) != .idle }
    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: prominent ? 17 : 15, weight: prominent ? .semibold : .medium))
                .lineLimit(stackedLevels ? 2 : 1).fixedSize(horizontal: false, vertical: true)
            if !showsStatus {
                Text(detail).font(.shared(.caption)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            } else if stackedLevels {
                AudioStateLabel(activity: activity, id: id, fallback: status)
                Text(detail).monospacedDigit().font(.shared(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 4) {
                    AudioStateLabel(activity: activity, id: id, fallback: status)
                    Text("· " + detail).font(.shared(.caption)).monospacedDigit().foregroundStyle(.secondary)
                }.lineLimit(1)
            }
            if canReplay { RecordingReplayControl(activity: activity, id: id) }
            // Every row keeps its meter, playing or not, so it is plain which device is making the sound.
            if stackedLevels { DeviceWaveform(activity: activity, id: id, strip: true).padding(.top, 2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            text
            if !stackedLevels { DeviceWaveform(activity: activity, id: id).frame(width: 84) }
        }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
    }
}

/// One line of connection quality for a paired device; the full report lives in device details.
private struct CompactPingLabel: View {
    @ObservedObject var monitor: PeerPingMonitor
    let peerID: String
    var body: some View {
        Text(monitor.label(for: peerID)).font(.shared(.caption)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            .help("Measures the network connection to this device, not total audio delay.")
    }
}

/// Menu entries for sending headphones to another host. Dragging the row onto that host's card does the same.
private struct MoveItems: View {
    @ObservedObject var store: HubStore
    let device: LocalAudioDevice
    let hostID: String
    let hostName: String
    var body: some View {
        if hostID != store.deviceID {
            Button("Move to \(store.name)") { store.requestDeviceMove(device, to: store.deviceID, from: hostName) }
        }
        ForEach(store.friends.filter { $0.id != hostID }) { peer in
            let online = store.nearby.contains { $0.id == peer.id }
            Button("Move to \(peer.card.name)" + (online ? "" : " (offline)")) {
                store.requestDeviceMove(device, to: peer.id, from: hostName)
            }.disabled(!online)
        }
    }
}

/// The vertical dots at the end of a device row. Quiet at rest, full strength under the pointer.
private struct RowMenu<Content: View>: View {
    let name: String
    let hovered: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu { content() } label: {
            Text("⋮").font(.system(size: 16, weight: .bold))
                .frame(width: 20, height: 32).contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .opacity(hovered ? 1 : 0.3)
        .animation(.easeInOut(duration: 0.12), value: hovered)
        #endif
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("Actions for \(name)")
        .help("Actions for \(name)")
    }
}

private struct DetailsToggle: View {
    @Binding var expanded: Bool
    let name: String
    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
                .frame(width: 28, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((expanded ? "Hide details for " : "Show details for ") + name)
        .help(expanded ? "Hide levels and latency" : "Show levels and latency")
    }
}

/// A labelled slider. `inline` is the single level shown on a collapsed device row.
private struct LevelRow<Control: View>: View {
    let label: String
    let percent: Int
    var inline = false
    @ViewBuilder var control: () -> Control
    @Environment(\.stackedLevels) private var stackedLevels
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.shared(.caption)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: inline ? 64 : 90, alignment: inline ? .trailing : .leading)
            // Beside the name when there is room; a full-width line of its own when the window is narrow.
            if inline && !stackedLevels { control().frame(width: 150) }
            else { control().frame(maxWidth: inline ? .infinity : 220) }
            Text("\(percent)%").font(.shared(.caption)).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            if !inline { Spacer(minLength: 0) }
        }
    }
}

private struct DeviceDragArea: ViewModifier {
    let id: String?
    let name: String
    @ViewBuilder func body(content: Content) -> some View {
        if let id {
            content.contentShape(Rectangle())
                .onDrag { NSItemProvider(object: id as NSString) } preview: {
                    Label(name, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
        } else { content }
    }
}

private struct DeviceDragHandle: View {
    let id: String
    let name: String
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(width: 24, height: 32)
            .contentShape(Rectangle())
            .accessibilityLabel("Drag \(name) to a room")
            .help("Drag \(name) to a room")
            .onDrag { NSItemProvider(object: id as NSString) }

    }
}

private struct DeviceRoomMenu: View {
    @ObservedObject var store: HubStore
    let id: String
    /// True for one of this device's own outputs, which may ask another room's owner to add or drop it.
    var ownOutput = false
    var body: some View {
        ForEach(store.rooms) { room in
            let remote = id.hasPrefix("remote:")
            let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
            let wholePeer = remote && parts.count == 3 && store.peerMemberships[parts[1]]?.contains(room.id) == true
            let belongs = store.audioMemberships[id]?.contains(room.id) == true || wholePeer || (!remote && store.audioDevice(id, belongsTo: room.id))
            let ownerName = store.friends.first(where: { $0.id == room.owner })?.card.name ?? "room owner"
            let verb = belongs ? "Remove from " : "Add to "
            if store.canAdminister(room) || room.role(of: store.deviceID) == .control {
                // The owner changes the room directly; a guest who can control asks the owner.
                Button(verb + room.name) { store.changeRoomMember(id, room: room, included: !belongs) }
            } else if ownOutput {
                Button(verb + room.name) { store.changeOwnRoomOutput(id, room: room, included: !belongs) }
            } else {
                Button(verb + room.name + " · ask " + ownerName + " for control") {}.disabled(true)
            }
        }
    }
}
private struct RemoteDeviceSettings: Identifiable {
    let device: LocalAudioDevice
    let peerID: String
    var id: String { HubStore.remoteComponentID(peer: peerID, component: device.id) }
}
private struct RemoteDeviceSettingsView: View {
    let selection: RemoteDeviceSettings
    @ObservedObject var store: HubStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(selection.device.name).font(.shared(.title2)); Spacer(); Button("Done") { dismiss() } }
            Text("These levels control audio on this device. Hardware settings are managed on the paired device.")
                .font(.shared(.caption)).foregroundStyle(.secondary)
            DeviceLatencyLabel(device: selection.device, online: store.nearby.contains { $0.id == selection.peerID })
            if selection.device.hasOutput { AudioGainControl(store: store, id: selection.id, name: selection.device.name, input: false) }
            if selection.device.hasInput { AudioGainControl(store: store, id: selection.id, name: selection.device.name, input: true) }
            PeerPingLabel(monitor: store.ping, peerID: selection.peerID)
            if store.developerMode { Text(store.ping.diagnostics(for: selection.peerID)).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }.padding(24)
        #if os(macOS)
        .frame(width: 560)
        #endif
    }
}

private struct LocalAudioRow: View {
    let device: LocalAudioDevice
    @ObservedObject var store: HubStore
    let action: (LocalAudioAction, String) -> Void
    let volumeChanged: (String, Double) -> Void
    @State private var level = 0.5
    @State private var editing = false
    @State private var showingSettings = false
    @State private var expanded = false
    @State private var hovered = false
    @Environment(\.stackedLevels) private var stackedLevels
    @ViewBuilder private var rowActions: some View {
            Button("Device settings") { showingSettings = true }
            // Whether this device sends sound to rooms, plays what others send, or both.
            Picker("This device", selection: Binding(get: { store.audioDirection }, set: { store.audioDirection = $0 })) {
                ForEach(AudioDirection.allCases) { Text($0.longTitle).tag($0) }
            }.pickerStyle(.inline)
            Button(store.audioGain(for: device.id, input: !device.hasOutput) == 0 ? "Unmute" : "Mute") { store.toggleAudioMute(for: device.id, input: !device.hasOutput) }
            if device.hasOutput {
                Button(store.activity.modes[device.id] == .chirping ? "Stop test audio" : "Play test audio") {
                    action(store.activity.modes[device.id] == .chirping ? .stopTest : .testOutput, device.id)
                }.disabled(!device.isAvailable)
            }
            Divider()
            if device.canMoveBetweenHosts {
                MoveItems(store: store, device: device, hostID: store.deviceID, hostName: store.name)
                Divider()
            }
            DeviceRoomMenu(store: store, id: device.id, ownOutput: device.hasOutput)
            if device.hasInput {
                Button("Share microphone with active room") { store.shareMicrophoneWithRoom(device) }
                    .disabled(store.activeRoom == nil)
                Button(store.activity.modes[device.id] == .recording ? "Stop recording" : "Record microphone") {
                    if store.activity.modes[device.id] == .recording { store.activity.endRecording(device.id) }
                    else { store.activity.beginRecording(device) }
                }
            }
    }
    /// True for the copy of a row shown inside a room card.
    var compact = false
    /// The same level leads wherever the device appears, so its room row and its Devices row always agree.
    private var leadsWithHardwareVolume: Bool { device.volume != nil }
    private func volumeRow(inline: Bool) -> some View {
        LevelRow(label: inline ? "Volume" : "Device volume", percent: Int(level * 100), inline: inline) {
            Slider(value: $level, in: 0...1) { isEditing in
                editing = isEditing
                if !isEditing { volumeChanged(device.id, level) }
            }
            .accessibilityLabel("Volume for \(device.name)").disabled(device.busy || !device.isAvailable)
        }
    }
    @ViewBuilder private var primaryLevel: some View {
        if leadsWithHardwareVolume { volumeRow(inline: true) }
        else if device.hasInput || device.hasOutput { AudioGainControl(store: store, id: device.id, name: device.name, input: device.hasInput && !device.hasOutput, inline: true)
                .disabled(!device.isAvailable || device.busy) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AudioDeviceGlyph(activity: store.activity, id: device.id, symbol: device.icon, name: device.name,
                    input: device.hasInput && !device.hasOutput ? device : nil,
                    inputAction: store.activeRoom.map { _ in { if store.roomAudio.active && store.roomAudio.sourceID == device.id { store.roomAudio.stop() } else { store.shareMicrophoneWithRoom(device) } } },
                    enabled: device.isAvailable && !device.busy,
                    muted: store.audioGain(for: device.id, input: !device.hasOutput) == 0,
                    toggleMute: { store.toggleAudioMute(for: device.id, input: !device.hasOutput) },
                    canTest: device.hasOutput) {
                    if device.hasOutput {
                        if store.activity.modes[device.id] == .chirping {
                            if store.mesh.active { store.mesh.stop() } else { action(.stopTest, device.id) }
                            store.activity.clear(device.id)
                        }
                        else { action(.testOutput, device.id) }
                    }
                    else { store.activity.showRecordingHint(device.id) }
                }
                DeviceRowText(name: device.name,
                    detail: device.connectionSummary(connected: device.isAvailable),
                    activity: store.activity, id: device.id, status: connectionStatus, canReplay: true,
                    statusInDetail: !device.isAvailable && connectionStatus == device.status)
                    .modifier(DeviceDragArea(id: "audio:" + device.id, name: device.name))
                if !stackedLevels {
                    Color.clear.frame(width: 264, height: 32).overlay { primaryLevel }
                }
                DetailsToggle(expanded: $expanded, name: device.name)
                RowMenu(name: device.name, hovered: hovered) { rowActions }.frame(width: 20)
            }
            if stackedLevels { primaryLevel.padding(.leading, 48) }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !leadsWithHardwareVolume, device.volume != nil { volumeRow(inline: false) }
                    if leadsWithHardwareVolume, device.hasOutput {
                        AudioGainControl(store: store, id: device.id, name: device.name, input: false)
                    }
                    if device.hasInput, device.hasOutput || leadsWithHardwareVolume {
                        AudioGainControl(store: store, id: device.id, name: device.name, input: true)
                    }
                    DeviceLatencyLabel(device: device)
                }.padding(.leading, 48).padding(.bottom, 4)
            }
            if device.awaitingTestAnswer {
                HStack {
                    Text("Did you hear it in your headphones?").font(.shared(.caption))
                    Button("Yes") { action(.heardSound, device.id) }
                    Button("No") { action(.didNotHearSound, device.id) }
                }.padding(.leading, 48)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { rowActions }
        .sheet(isPresented: $showingSettings) {
            AudioDeviceSettingsView(device: device, store: store, action: action)
        }
        .onAppear { level = device.volume ?? 0.5 }
        .onChange(of: device.volume) { value in if !editing { level = value ?? 0.5 } }
        .onChange(of: level) { value in
            if let actual = device.volume, abs(value - actual) > 0.005 { volumeChanged(device.id, value) }
        }
    }
    private var connectionStatus: String {
        guard let state = store.audioDeviceStates[device.id] else { return device.status }
        if state.transition == .failed { return "Change not confirmed" }
        guard state.transition == .pending else { return device.status }
        switch state.intent {
        case .connect: return "Connecting…"
        case .disconnect: return "Disconnecting…"
        case .useInput: return "Changing input…"
        case .useOutput: return "Changing output…"
        case .none: return device.status
        }
    }
}

private struct DeviceLatencyLabel: View {
    let device: LocalAudioDevice
    var online = true
    private func line(_ name: String, _ value: Double?) -> String {
        if let value = AudioDeviceLatency.valid(value) { return "\(name): \(String(format: "%.1f", value)) ms" }
        return "\(name): not reported"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !online || !device.isAvailable {
                Text("Latency: not connected")
            } else {
                if device.hasInput { Text(line("OS input", device.latency?.inputMilliseconds)) }
                if device.hasOutput { Text(line("OS output", device.latency?.outputMilliseconds)) }
                if let buffer = device.latency?.ioBufferMilliseconds { Text(line("I/O buffer", buffer)) }
                if let buffer = device.latency?.playbackBufferMilliseconds { Text(line("Queued audio", buffer)) }
                if let target = device.latency?.playbackTargetMilliseconds { Text(line("Buffer target", target)) }
                if let recoveries = device.latency?.playbackRecoveries { Text("Buffer recoveries: \(recoveries)") }
                if device.hasOutput { Text("Audible delay: not measured") }
            }
        }
        .font(.shared(.caption)).monospacedDigit().foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .help("OS input/output is the latency reported by the device or audio session. I/O buffer is the current hardware buffer duration. These are separate components, not end-to-end latency; capture, conversion, network and Soundbound buffering can add delay.")
    }
}

private struct AudioGainControl: View {
    @ObservedObject var store: HubStore
    let id: String
    let name: String
    let input: Bool
    var inline = false
    var label: String { input ? (id.hasPrefix("remote:") ? "Record gain" : "Mic gain") : (id.hasPrefix("remote:") ? "Send level" : "Playback") }
    var body: some View {
        LevelRow(label: label, percent: Int((store.audioGain(for: id, input: input) * 100).rounded()), inline: inline) {
            Slider(value: Binding(get: { store.audioGain(for: id, input: input) },
                set: { store.setAudioGain($0, for: id, input: input) }), in: 0...1)
                .accessibilityLabel("Soundbound \(label.lowercased()) for \(name)")
                .help(input ? (id.hasPrefix("remote:") ? "Adjust recordings received on this device; the remote microphone setting is unchanged." : "Adjust microphone audio recorded or shared through Soundbound.") : (id.hasPrefix("remote:") ? "Adjust sound sent from this device to that output, without changing remote hardware volume." : "Adjust Soundbound playback only. This setting is saved while disconnected."))
        }
    }
}

private struct AudioDeviceSettingsView: View {
    let device: LocalAudioDevice
    @ObservedObject var store: HubStore
    let action: (LocalAudioAction, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingAction: LocalAudioAction?
    private func setting(_ path: WritableKeyPath<AudioDevicePolicy, Bool>) -> Binding<Bool> {
        Binding(get: { store.policy(for: device.id)[keyPath: path] }, set: { value in
            var policy = store.policy(for: device.id)
            policy[keyPath: path] = value
            store.setPolicy(policy, for: device.id)
        })
    }
    private func request(_ choice: LocalAudioAction) {
        if store.policy(for: device.id).askBeforeChanges { pendingAction = choice }
        else { action(choice, device.id); dismiss() }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label(device.name, systemImage: device.icon).font(.shared(.title3, weight: .medium))
                    Text(device.status).font(.shared(.subheadline)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Use this device").font(.shared(.headline))
                        if device.hasOutput { Button(device.selectedOutput ? "Selected for this device" : "Use for this device") { request(.useOutput) }.disabled(device.selectedOutput || device.busy) }
                        if device.hasInput { Button(device.selectedInput ? "Selected microphone" : "Use as microphone") { request(.useInput) }.disabled(device.selectedInput || device.busy) }
                        if device.canConnect { Button("Connect here") { request(.connect) }.disabled(device.busy) }
                        if device.canDisconnect { Button("Disconnect here") { request(.disconnect) }.disabled(device.busy) }
                        if device.canTest { Button("Test sound") { action(.testSound, device.id); dismiss() }.disabled(device.busy) }
                    }.buttonStyle(.bordered)
                    if device.connection == .bluetooth {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Stop Apple’s automatic switching").font(.shared(.headline))
                            Text("In your AirPods settings, set Connect to This Mac and Connect to This iPhone to When Last Connected. Do this on both devices.")
                                .font(.shared(.subheadline)).fixedSize(horizontal: false, vertical: true)
                            Text("Soundbound asks before its own moves. Apple’s automatic handoffs bypass those requests.")
                                .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Link("Apple’s setup instructions", destination: URL(string: "https://support.apple.com/104988")!)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("When things change").font(.shared(.headline))
                        Toggle("Ask before Soundbound switches this device", isOn: setting(\.askBeforeChanges))
                        Toggle("Tell me when its connection or route changes", isOn: setting(\.notifyChanges))
                        Toggle("Remove from room when disconnected", isOn: setting(\.removeWhenDisconnected))
                        Text("Removal waits three seconds for brief dropouts. Apple’s automatic switches can only be detected afterward; these settings cannot block them.")
                            .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.toggleStyle(.switch)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Room").font(.shared(.headline))
                        ForEach(store.rooms) { room in
                            Toggle(room.name, isOn: Binding(
                                get: { store.audioMemberships[device.id]?.contains(room.id) == true },
                                set: { joined in
                                    if joined { store.moveAudioDevice(device.id, to: room.id) }
                                    else { store.removeAudioDevice(device.id, from: room.id) }
                                })).disabled(room.owner != store.deviceID)
                        }
                        Text("A device can belong to more than one room.").font(.shared(.caption)).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Device settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Change this device’s connection?", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
                Button("Confirm change") {
                    if let pendingAction { action(pendingAction, device.id) }
                    pendingAction = nil
                    dismiss()
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 620)
        #endif
    }
}

private struct EmptyHint: View {
    let icon: String; let title: String; let detail: String
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(title).font(.shared(.title3, weight: .medium))
            Text(detail).font(.shared(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }.frame(maxWidth: .infinity).padding(.vertical, 52)
    }
}

private struct HomeDeviceRow: View {
    let name: String
    let owner: String
    let kind: String
    @ObservedObject var activity: DeviceAudioActivity
    let activityID: String
    var componentIDs: [String] = []
    var nearby = false
    var isLocal = false
    var dragID: String? = nil
    var settingsAction: (() -> Void)? = nil
    var testAction: (() -> Void)? = nil
    var ping: PeerPingMonitor? = nil
    @Environment(\.stackedLevels) private var stackedLevels
    var body: some View {
        let meterID = activity.meterID(host: activityID, components: componentIDs)
        HStack(spacing: 8) {
            AudioDeviceGlyph(activity: activity, id: meterID,
                symbol: kind == "mac" ? "laptopcomputer" : "iphone", name: name,
                enabled: testAction != nil) { testAction?() }
            DeviceRowText(name: name, detail: owner, activity: activity, id: meterID,
                          status: isLocal ? "This device" : (nearby ? "Nearby" : "Offline"), prominent: true)
            if !stackedLevels {
                // Match the level, details and menu columns in component rows.
                Color.clear.frame(width: 328, height: 1)
                    .overlay(alignment: .trailing) {
                        if !isLocal, let ping, let peerID = dragID.map({ String($0.dropFirst(5)) }) {
                            CompactPingLabel(monitor: ping, peerID: peerID)
                        }
                    }
            } else if !isLocal, let ping, let peerID = dragID.map({ String($0.dropFirst(5)) }) {
                CompactPingLabel(monitor: ping, peerID: peerID)
            }
        }.padding(.vertical, 8)
            .modifier(DeviceDragArea(id: dragID, name: name))
            .contextMenu { if let settingsAction { Button("Device settings", action: settingsAction) } }
    }
}

public struct PeerPingLabel: View {
    @ObservedObject private var monitor: PeerPingMonitor
    private let peerID: String
    public init(monitor: PeerPingMonitor, peerID: String) { self.monitor = monitor; self.peerID = peerID }
    public var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(monitor.label(for: peerID) == "Offline" ? "Network RTT: offline" : monitor.label(for: peerID)).monospacedDigit()
            if let connection = monitor.connectionLabel(for: peerID) {
                Text(connection)
                Text("Bonjour discovery")
            }
            Text("Speaker delay: not measured")
        }.font(.shared(.caption)).foregroundStyle(.secondary)
            // DeviceRowText has a higher layout priority. A flexible maximum
            // lets it squeeze this label to zero width and thousands of points
            // tall; reserve the diagnostic column's width instead.
            .frame(width: 190, alignment: .trailing)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .help("Ping measures an encrypted echo on the open audio connection. Probe includes a new connection and signed response when idle. Neither measures total audio delay. Bonjour discovers peers; Bluetooth connects output hardware.")
    }
}

private struct HomeView: View {
    @ObservedObject var store: HubStore
    let localAudioDevices: [LocalAudioDevice]
    let audioMessage: String?
    let onAudioAction: (LocalAudioAction, String) -> Void
    let onAudioVolume: (String, Double) -> Void
    @State private var showingDeviceSettings = false
    @State private var addingFriend = false
    @State private var addingPeople = false
    @State private var adding = false
    @State private var roomSettings: AudioRoom?
    @State private var deletingRoom: AudioRoom?
    @State private var showingDeleteConfirmation = false
    @StateObject private var roomTest = RoomPlaybackTest()
    @State private var hoveredRoom: String?
    @State private var remoteSettings: RemoteDeviceSettings?
    @State private var spatialRoom: AudioRoom?
    @State private var overDevices = false
    @State private var hoveredHost: String?
    @State private var guestsRoom: AudioRoom?
    var body: some View {
        GeometryReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if store.identityLoading {
                    Label(Identity.usesDevelopmentFile ? "Loading device identity…" : "Unlock your device identity in the Keychain prompt.", systemImage: "lock")
                        .font(.shared(.caption)).foregroundStyle(.secondary)
                }
                ForEach(store.requests) { request in pairingRequest(request) }
                roomsSection
                devicesSection
                FriendsSection(store: store, adding: $showingDeviceSettings, addFriend: { addingPeople = true; addingFriend = true })
            }
            .padding(.horizontal, pageMargin).padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .environment(\.stackedLevels, proxy.size.width < 680)
        }
        .background(canvasColor)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HomeAudioStatus(store: store, mesh: store.mesh, roomAudio: store.roomAudio, activity: store.activity, roomTest: roomTest,
                localMessage: audioMessage, stopRoom: { store.setActiveRoom(nil) })
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingDeviceSettings) {
            NavigationStack {
                SettingsView(store: store)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDeviceSettings = false } } }
            }
            #if os(macOS)
            .frame(width: 580, height: 640)
            #endif
        }
        .sheet(isPresented: $adding) { NewRoomView(store: store) }
        .sheet(isPresented: $addingFriend) { AddFriendView(store: store, people: addingPeople) }
        .sheet(item: $remoteSettings) { RemoteDeviceSettingsView(selection: $0, store: store) }
        .sheet(item: $guestsRoom) { room in RoomGuestsView(store: store, roomID: room.id) }
        .sheet(item: $spatialRoom) { room in
            RoomSpatialView(store: store, roomID: room.id, localDevices: localAudioDevices)
        }
        .alert("Delete room?", isPresented: $showingDeleteConfirmation) {
            Button("Delete room", role: .destructive) {
                if let room = deletingRoom { store.deleteRoom(room.id) }
                deletingRoom = nil
            }
            Button("Cancel", role: .cancel) { deletingRoom = nil }
        } message: {
            Text("The devices stay paired. Only this room and its grouping are removed.")
        }
        .sheet(item: $roomSettings) { room in
            NavigationStack {
                RoomView(store: store, roomID: room.id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { roomSettings = nil } } }
            }
            #if os(macOS)
            .frame(width: 580, height: 620)
            #endif
        }
    }
    private func sectionHeader(_ title: String, add: String, accessibility: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.shared(.title3, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: action) { Label(add, systemImage: "plus") }
                .buttonStyle(PillButtonStyle()).accessibilityLabel(accessibility)
        }
    }
    private func pairingRequest(_ request: AccessRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(request.peer.name) wants to pair").font(.shared(.headline))
            Text("Pairing allows audio playback. It never turns on a microphone.").font(.shared(.caption)).foregroundStyle(.secondary)
            Text("Device fingerprint: \(request.peer.id.prefix(8).uppercased())")
                .font(.shared(.caption)).foregroundStyle(.secondary)
            HStack {
                Button("Allow") { store.decide(request, approve: true) }.buttonStyle(.borderedProminent)
                Button("Decline") { store.decide(request, approve: false) }.buttonStyle(.bordered)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).soundboundPanel()
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5).allowsHitTesting(false))
    }
    private var roomsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Rooms", add: "New room", accessibility: "Add a room") { adding = true }
            if store.rooms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Make a room. Fill it with sound.").font(.shared(.headline))
                    Text("A room is the set of speakers and headphones you want playing together.")
                        .font(.shared(.subheadline)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Create your first room") { adding = true }.buttonStyle(PillButtonStyle(prominent: true))
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .soundboundPanel()
            }
            ForEach(store.rooms) { room in roomCard(room) }
        }
    }
    @ViewBuilder private func roomActions(_ room: AudioRoom) -> some View {
        Menu("Network") {
            // One section per nearby device: Automatic, or one of the routes measured to it with its round trip.
            ForEach(store.friends.filter { peer in store.nearby.contains { $0.id == peer.id } }) { peer in
                Section(store.deviceTitle(peer)) {
                    let pinned = store.ping.pinnedRoutes[peer.id]
                    Button { store.ping.selectRoute(nil, for: peer.id) } label: {
                        Label("Automatic · fastest route", systemImage: pinned == nil ? "checkmark" : "")
                    }
                    ForEach(store.ping.routeChoices[peer.id] ?? []) { route in
                        Button { store.ping.selectRoute(route.host, for: peer.id) } label: {
                            Label((route.interface.isEmpty ? route.host : route.interface) + " · " +
                                  (route.milliseconds.map { String(format: "%.1f ms", $0) } ?? "no reply"),
                                  systemImage: pinned == route.host ? "checkmark" : "")
                        }.disabled(route.milliseconds == nil)
                    }
                    Button(store.ping.testingRoutes(for: peer.id) ? "Measuring…" : "Measure routes again") { store.ping.testRoutes(to: peer.id) }
                        .disabled(store.ping.testingRoutes(for: peer.id))
                }
            }
            Section { Text("Bluetooth, WebRTC and relay routes are not available yet.") }
        }
        Button("Guests") { guestsRoom = room }
        Button("3D room / scan") { spatialRoom = room }
        Button("Room settings") { roomSettings = room }.disabled(!store.canAdminister(room))
        Button("Delete room", role: .destructive) {
            deletingRoom = room
            showingDeleteConfirmation = true
        }.disabled(!store.canAdminister(room))
    }
    private func roomSubtitle(_ room: AudioRoom) -> String {
        let holder = store.friends.first(where: { $0.id == room.owner })?.card.name ?? "Paired device"
        let base = room.owner == store.deviceID ? room.region : store.isOwnDevice(room.owner) ? "Yours · on " + holder : "Synced · " + holder
        let count = room.guests?.count ?? 0
        let mine = room.role(of: store.deviceID).map { " · you " + $0.rawValue.lowercased() } ?? ""
        return base + (count == 0 ? "" : count == 1 ? " · 1 guest" : " · \(count) guests") + mine
    }
    private func roomMeterIDs(_ room: AudioRoom) -> [String] {
        let local = localAudioDevices.filter { store.audioDevice($0.id, belongsTo: room.id) }.map(\.id)
        let remote = store.friends.flatMap { peer in
            store.displayedPeerDevices(peer.id).compactMap { component -> String? in
                let id = HubStore.remoteComponentID(peer: peer.id, component: component.id)
                return store.peerMemberships[peer.id]?.contains(room.id) == true ||
                    store.audioMemberships[id]?.contains(room.id) == true ? id : nil
            }
        }
        return local + remote
    }
    private func roomCard(_ room: AudioRoom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RoomHeading(name: room.name, subtitle: roomSubtitle(room), activity: store.activity,
                        id: "room:" + room.id, componentIDs: roomMeterIDs(room)) {
                Button { testRoom(room) } label: {
                    Image(systemName: "play.circle").font(.system(size: 18))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(roomTest.active)
                    .accessibilityLabel("Play a test sound in \(room.name)")
                    .help("Broadcast a test sound to this room’s available speakers; tap again to stop")
                RoomLiveControl(store: store, audio: store.roomAudio, room: room)
                Menu { roomActions(room) } label: {
                    Text("⋮").font(.system(size: 18, weight: .bold))
                        .frame(width: 24, height: 32).contentShape(Rectangle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                #endif
                .accessibilityLabel("Room actions").help("Room actions")
            }
            .contentShape(Rectangle())
            Divider()
            VStack(spacing: 0) {
                if store.deviceRooms.contains(room.id) { roomDeviceRow(stacked: false) }
                ForEach(localAudioDevices.filter { store.audioDevice($0.id, belongsTo: room.id) }) { device in
                    LocalAudioRow(device: device, store: store, action: onAudioAction, volumeChanged: onAudioVolume, compact: true)
                        .padding(.leading, store.deviceRooms.contains(room.id) ? nestedDeviceIndent : 0)
                }
                ForEach(store.friends.filter { store.peerMemberships[$0.id]?.contains(room.id) == true }) { peer in
                    peerRow(peer)
                    ForEach(store.displayedPeerDevices(peer.id)) { component in
                        remoteComponentRow(component, peer: peer).padding(.leading, nestedDeviceIndent)
                    }
                }
                ForEach(store.friends.filter { store.peerMemberships[$0.id]?.contains(room.id) != true }) { peer in
                    ForEach(store.displayedPeerDevices(peer.id).filter {
                        store.audioMemberships[HubStore.remoteComponentID(peer: peer.id, component: $0.id)]?.contains(room.id) == true
                    }) { component in
                        remoteComponentRow(component, peer: peer)
                    }
                }
            }
            Menu {
                ForEach(localAudioDevices.filter { $0.hasOutput || $0.hasInput }) { device in
                    let included = store.audioDevice(device.id, belongsTo: room.id)
                    Button {
                        if device.hasInput && !device.hasOutput {
                            store.changeRoomMember(device.id, room: room, included: true)
                        } else {
                            store.changeOwnRoomOutput(device.id, room: room, included: true)
                        }
                    } label: { Label(device.name, systemImage: included ? "checkmark" : device.icon) }
                    .disabled(included)
                }
                if room.owner == store.deviceID {
                    ForEach(store.friends) { peer in
                        let devices = (store.peerAudioDevices[peer.id] ?? []).filter { $0.hasOutput || $0.hasInput }
                        ForEach(devices) { device in
                            let key = HubStore.remoteComponentID(peer: peer.id, component: device.id)
                            let included = roomIncludesRemoteOutput(store: store, key: key, peerID: peer.id, roomID: room.id)
                            Button { store.moveAudioDevice(key, to: room.id) } label: {
                                Label("\(device.name) · \(peer.card.name)", systemImage: included ? "checkmark" : device.icon)
                            }.disabled(included)
                        }
                    }
                }
            } label: {
                Label(roomDeviceDropTitle(hovered: hoveredRoom == room.id), systemImage: "plus")
                    .font(.shared(.caption)).frame(maxWidth: .infinity).padding(12)
                    .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }.menuStyle(.borderlessButton)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .soundboundPanel()
            .overlay(RoomActiveBorder(store: store, audio: store.roomAudio, roomID: room.id))
            .contextMenu { roomActions(room) }
            .overlay(dropOutline(active: hoveredRoom == room.id))
            .contentShape(Rectangle())
            .onDrop(of: [UTType.plainText], isTargeted: Binding(
                get: { hoveredRoom == room.id },
                set: { hoveredRoom = $0 ? room.id : nil }
            )) { acceptDrop($0, roomID: room.id) }
    }
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Devices", add: "Add device", accessibility: "Add a device") { addingPeople = false; addingFriend = true }
            if store.friends.isEmpty {
                Text("Your devices connect automatically when signed in to the same Apple Account. Keep Soundbound open on both devices on the same local network. Use Add device for other devices.")
                    .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    HomeDeviceRow(name: store.name, owner: "You", kind: HubStore.kind, activity: store.activity, activityID: store.deviceID, componentIDs: localAudioDevices.map(\.id), nearby: true, isLocal: true, dragID: store.deviceID, settingsAction: { showingDeviceSettings = true }, testAction: testLocalHost)
                        .contextMenu {
                            ForEach(store.rooms) { room in
                                Button("Add to \(room.name)") { store.moveDevice(to: room.id) }
                            }
                            ForEach(store.rooms.filter { store.host(store.deviceID, isIn: $0.id) }) { room in
                                Button("Remove from \(room.name)") { store.removeHost(store.deviceID, from: room) }
                            }
                        }
                    VStack(spacing: 0) {
                        ForEach(localAudioDevices) { device in
                            Divider().padding(.leading, 48)
                            LocalAudioRow(device: device, store: store, action: onAudioAction, volumeChanged: onAudioVolume)
                        }
                    }.modifier(HostChildren())
                }
                .padding(.horizontal, 16).padding(.vertical, 6).soundboundPanel()
                .modifier(hostDropTarget(store.deviceID))
                ForEach(store.friends) { peer in
                    VStack(spacing: 0) {
                        peerRow(peer)
                        let reported = store.peerAudioDevices[peer.id] ?? []
                        let remembered = reported.isEmpty ? (store.lastKnownPeerDevices[peer.id] ?? []) : []
                        let online = store.nearby.contains { $0.id == peer.id }
                        VStack(spacing: 0) {
                            ForEach(reported) { component in
                                Divider().padding(.leading, 48)
                                remoteComponentRow(component, peer: peer)
                            }
                            // Last-known parts of a device that is away: listed, dimmed, levels still adjustable.
                            ForEach(remembered) { component in
                                Divider().padding(.leading, 48)
                                RemoteComponentRow(component: component, peer: peer, store: store, ping: store.ping, away: true) {
                                    remoteSettings = RemoteDeviceSettings(device: component, peerID: peer.id)
                                }
                            }
                        }.modifier(HostChildren())
                        if reported.isEmpty {
                            Label(online ? "Waiting for its speakers and microphones…"
                                         : (remembered.isEmpty
                                            ? "Open Soundbound on \(peer.card.name) to see its speakers and microphones."
                                            : "Away. Open Soundbound on \(peer.card.name) to use these or to send headphones to it."),
                                  systemImage: online ? "ellipsis" : "moon.zzz")
                                .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 48).padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6).soundboundPanel()
                    .modifier(hostDropTarget(peer.id))
                }
            }
            .overlay(dropOutline(active: overDevices))
            .contentShape(Rectangle())
            .onDrop(of: [UTType.plainText], isTargeted: $overDevices) { acceptDrop($0, roomID: nil) }
        }
    }
    private func testLocalHost() {
        if let output = localAudioDevices.first(where: { $0.hasOutput && $0.selectedOutput }) {
            if store.activity.modes[output.id] == .chirping {
                if store.mesh.active { store.mesh.stop() } else { onAudioAction(.stopTest, output.id) }
                store.activity.clear(output.id); store.activity.clear(store.deviceID)
            }
            else { onAudioAction(.testOutput, output.id) }
        }
    }
    private func testRoom(_ room: AudioRoom) {
        store.emitRoomTest(room)
    }
    private func dropOutline(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(active ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(active ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 18))
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.15), value: active)
    }
    private func acceptDrop(_ providers: [NSItemProvider], roomID: String?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String else { return }
            DispatchQueue.main.async { applyRoomDrop(value, roomID: roomID) }
        }
        return true
    }
    /// A room held by another device that this device may still change: one of your own, or one you control as a guest.
    private func remotelyHeld(_ roomID: String?) -> AudioRoom? {
        guard let room = store.rooms.first(where: { $0.id == roomID }), room.owner != store.deviceID,
              store.isOwnDevice(room.owner) || room.role(of: store.deviceID) == .control else { return nil }
        return room
    }
    private func applyRoomDrop(_ value: String, roomID: String?) {
        guard store.identity != nil else { return }
        if value == store.deviceID {
            store.moveDevice(to: roomID)
        } else if value.hasPrefix("audio:") {
            let id = String(value.dropFirst(6))
            guard localAudioDevices.contains(where: { $0.id == id }) else { return }
            if let room = remotelyHeld(roomID) { store.changeRoomMember(id, room: room, included: true) }
            else { store.moveAudioDevice(id, to: roomID) }
        } else if value.hasPrefix("remote:") {
            guard store.friends.contains(where: { peer in
                (store.peerAudioDevices[peer.id] ?? []).contains {
                    HubStore.remoteComponentID(peer: peer.id, component: $0.id) == value
                }
            }) else { return }
            if let room = remotelyHeld(roomID) { store.changeRoomMember(value, room: room, included: true) }
            else { store.moveAudioDevice(value, to: roomID) }
        } else if value.hasPrefix("peer:") {
            store.movePeer(String(value.dropFirst(5)), to: roomID)
        }
    }
    /// A dragged item that is wireless headphones, with the host they are currently attached to.
    private func movableDevice(_ value: String) -> (device: LocalAudioDevice, hostID: String, hostName: String)? {
        if value.hasPrefix("audio:") {
            let id = String(value.dropFirst(6))
            if let device = localAudioDevices.first(where: { $0.id == id }), device.canMoveBetweenHosts {
                return (device, store.deviceID, store.name)
            }
            return nil
        }
        for peer in store.friends {
            if let device = (store.peerAudioDevices[peer.id] ?? []).first(where: {
                HubStore.remoteComponentID(peer: peer.id, component: $0.id) == value
            }), device.canMoveBetweenHosts { return (device, peer.id, peer.card.name) }
        }
        return nil
    }
    /// Dropping headphones on another host's card asks that host to take them over.
    /// Anything else dropped on Devices leaves its rooms, as before.
    private func acceptCardDrop(_ providers: [NSItemProvider], hostID: String) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String else { return }
            DispatchQueue.main.async {
                if let move = movableDevice(value), move.hostID != hostID {
                    store.requestDeviceMove(move.device, to: hostID, from: move.hostName)
                } else { applyRoomDrop(value, roomID: nil) }
            }
        }
        return true
    }
    private func hostDropTarget(_ hostID: String) -> HostDropTarget {
        HostDropTarget(active: hoveredHost == hostID,
                       targeted: Binding(get: { hoveredHost == hostID }, set: { hoveredHost = $0 ? hostID : nil }),
                       accept: { acceptCardDrop($0, hostID: hostID) })
    }
    private func acceptHostDrop(_ providers: [NSItemProvider], hostID: String) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String else { return }
            DispatchQueue.main.async {
                let local = value.hasPrefix("audio:") ? localAudioDevices.first { $0.id == String(value.dropFirst(6)) } : nil
                let remote = store.friends.flatMap { peer in
                    (store.peerAudioDevices[peer.id] ?? []).filter {
                        HubStore.remoteComponentID(peer: peer.id, component: $0.id) == value
                    }
                }.first
                if let device = local ?? remote {
                    let sourceName = local != nil ? store.name : store.friends.first(where: { peer in
                        (store.peerAudioDevices[peer.id] ?? []).contains { HubStore.remoteComponentID(peer: peer.id, component: $0.id) == value }
                    })?.card.name
                    store.requestDeviceMove(device, to: hostID, from: sourceName)
                }
                else { store.notice = "Drop wireless headphones here to request a connection. Devices themselves belong in rooms." }
            }
        }
        return true
    }

    private func remoteComponentRow(_ component: LocalAudioDevice, peer: KnownPeer) -> some View {
        RemoteComponentRow(component: component, peer: peer, store: store, ping: store.ping,
                           away: store.peerAudioDevices[peer.id]?.isEmpty != false) {
            remoteSettings = RemoteDeviceSettings(device: component, peerID: peer.id)
        }
    }

    private func peerRow(_ peer: KnownPeer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
        HomeDeviceRow(name: peer.card.name, owner: store.isOwnDevice(peer.id) ? "You · Apple Account" : store.ownerName(of: peer) ?? "Paired device", kind: peer.card.kind, activity: store.activity, activityID: "peer:" + peer.id,
            componentIDs: (store.peerAudioDevices[peer.id] ?? []).map { HubStore.remoteComponentID(peer: peer.id, component: $0.id) },
            nearby: store.nearby.contains { $0.id == peer.id }, dragID: "peer:" + peer.id, testAction: {
                let mode = store.activity.modes["peer:" + peer.id]
                if mode == .chirping || mode == .waiting { store.mesh.stop() }
                else { store.sendAudioTest(to: peer.id) }
            }, ping: store.ping)
        if store.developerMode {
            DisclosureGroup("Connection diagnostics") {
                VStack(alignment: .leading, spacing: 6) {
                    RouteTestControls(monitor: store.ping, peerID: peer.id)
                    Text(store.ping.diagnostics(for: peer.id)).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.font(.shared(.caption)).foregroundStyle(.secondary).padding(.leading, 48).padding(.bottom, 6)
        }
        }
            .contextMenu {
                Button("Test connection routes") { store.ping.testRoutes(to: peer.id) }
                    .disabled(!store.nearby.contains { $0.id == peer.id })
                ForEach(store.rooms) { room in
                    Button("Add to \(room.name)") { store.movePeer(peer.id, to: room.id) }
                }
                ForEach(store.rooms.filter { store.host(peer.id, isIn: $0.id) }) { room in
                    Button("Remove from \(room.name)") { store.removeHost(peer.id, from: room) }
                }
            }
    }
    private func roomDeviceRow(stacked: Bool) -> some View {
        HomeDeviceRow(name: store.name, owner: "You", kind: HubStore.kind, activity: store.activity, activityID: store.deviceID, componentIDs: localAudioDevices.map(\.id),
                      nearby: true, isLocal: true, dragID: store.deviceID, settingsAction: { showingDeviceSettings = true }, testAction: testLocalHost)
            .contextMenu {
                ForEach(store.rooms.filter { store.host(store.deviceID, isIn: $0.id) }) { room in
                    Button("Remove from \(room.name)") { store.removeHost(store.deviceID, from: room) }
                }
            }
    }

}

/// One control for a room's state: Off, Live (green text), or carrying sound (green fill, white text).
/// On a Mac that can share application audio, the share action joins the same capsule while the room is live.
private struct RoomLiveControl: View {
    @ObservedObject var store: HubStore
    @ObservedObject var audio: RoomAudio
    let room: AudioRoom
    @Environment(\.stackedLevels) private var stackedLevels
    var body: some View {
        let live = store.activeRoomID == room.id
        HStack(spacing: 0) {
            Button { store.setActiveRoom(live ? nil : room.id) } label: {
                Label(live ? "Leave" : "Join", systemImage: live ? "rectangle.portrait.and.arrow.right" : "plus")
                    .lineLimit(1)
                    .font(.shared(.subheadline, weight: .semibold))
                    .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(live ? "Take this device out of the room" : "Bring this device into the room")
                .accessibilityLabel(live ? "Leave \(room.name)" : "Join \(room.name)")
        }
        .fixedSize(horizontal: true, vertical: false)
        // Join is the invitation, so it is green; Leave is quiet. The room's green outline says you are in.
        .foregroundStyle(live ? Color.primary : Color.white)
        .background(live ? Color.primary.opacity(0.08) : liveGreen, in: Capsule())
        .animation(.easeInOut(duration: 0.15), value: live)
    }
}

/// The green outline means this device has joined the room; it thickens while sound is moving through it.
private struct RoomActiveBorder: View {
    @ObservedObject var store: HubStore
    @ObservedObject var audio: RoomAudio
    let roomID: String
    var body: some View {
        let joined = store.activeRoomID == roomID
        let carrying = joined && (audio.active || audio.receiving || store.roomHasPeerPlayback(roomID))
        RoundedRectangle(cornerRadius: 18).strokeBorder(joined ? liveGreen : .clear, lineWidth: carrying ? 2.5 : 1.5)
            .animation(.easeInOut(duration: 0.15), value: joined)
            .allowsHitTesting(false).animation(.easeInOut(duration: 0.15), value: carrying)
    }
}

private struct HostDropTarget: ViewModifier {
    let active: Bool
    let targeted: Binding<Bool>
    let accept: ([NSItemProvider]) -> Bool
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(active ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .background(active ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 18))
                .allowsHitTesting(false).animation(.easeInOut(duration: 0.15), value: active))
            .contentShape(Rectangle())
            .onDrop(of: [UTType.plainText], isTargeted: targeted, perform: accept)
    }
}

private struct RemoteComponentRow: View {
    let component: LocalAudioDevice
    let peer: KnownPeer
    @ObservedObject var store: HubStore
    /// Observed so the row's connection type and delay follow the link as it is measured.
    @ObservedObject var ping: PeerPingMonitor
    /// True for a remembered part of a device that is currently offline.
    var away = false
    private var connected: Bool { !away && component.isAvailable }
    let openSettings: () -> Void
    @State private var expanded = false
    @State private var hovered = false
    @Environment(\.stackedLevels) private var stackedLevels
    private var id: String { HubStore.remoteComponentID(peer: peer.id, component: component.id) }
    @ViewBuilder private var primaryLevel: some View {
        if component.hasInput || component.hasOutput {
            AudioGainControl(store: store, id: id, name: component.name, input: component.hasInput && !component.hasOutput, inline: true)
                .disabled(away || !component.isAvailable)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AudioDeviceGlyph(activity: store.activity, id: id, symbol: component.icon, name: component.name,
                    enabled: component.isAvailable && !away,
                    muted: store.audioGain(for: id, input: !component.hasOutput) == 0,
                    toggleMute: { store.toggleAudioMute(for: id, input: !component.hasOutput) },
                    canTest: component.hasOutput && !away,
                    recordOnDoubleTap: component.hasInput && !component.hasOutput && !away) {
                    if component.hasInput && !component.hasOutput { store.toggleRemoteRecording(peerID: peer.id, inputID: component.id) }
                    else if store.activity.modes[id] == .chirping || store.activity.modes[id] == .waiting { store.mesh.stop(); store.activity.clear(id) }
                    else { store.sendAudioTest(to: peer.id, outputID: component.id) }
                }
                DeviceRowText(name: component.name,
                    detail: component.connectionSummary(connected: connected, remote: true,
                        network: ping.transportLabel(for: peer.id), roundTrip: ping.roundTrip(for: peer.id)?.milliseconds),
                    activity: store.activity, id: id,
                    status: away ? "Away" : component.selectedOutput || component.selectedInput ? "Selected" : component.isAvailable ? "Available" : "Not connected",
                    statusInDetail: !connected && !away)
                    .modifier(DeviceDragArea(id: away ? nil : id, name: component.name))
                    .opacity(away ? 0.55 : 1)
                if !stackedLevels {
                    Color.clear.frame(width: 264, height: 32).overlay { primaryLevel }
                }
                DetailsToggle(expanded: $expanded, name: component.name)
                RowMenu(name: component.name, hovered: hovered) { rowActions }.frame(width: 20)
            }
            if stackedLevels { primaryLevel.padding(.leading, 48) }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if component.hasInput && component.hasOutput {
                        AudioGainControl(store: store, id: id, name: component.name, input: true)
                    }
                    DeviceLatencyLabel(device: component, online: store.nearby.contains { $0.id == peer.id })
                }.padding(.leading, 48).padding(.bottom, 4)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { rowActions }
    }
    @ViewBuilder private var rowActions: some View {
            Button("Device settings", action: openSettings)
            // Send, receive or both for the device this speaker or microphone belongs to. Offered where this device
            // may change it; the other device has the final say and the choice shown is what it last reported.
            if store.mayTune(peer.id), !away {
                Picker(peer.card.name, selection: Binding(get: { store.peerDirections[peer.id] ?? .both },
                                                         set: { store.setDirection($0, on: peer.id) })) {
                    ForEach(AudioDirection.allCases) { Text($0.longTitle).tag($0) }
                }.pickerStyle(.inline)
            }
            Button(store.audioGain(for: id, input: !component.hasOutput) == 0 ? "Unmute" : "Mute") { store.toggleAudioMute(for: id, input: !component.hasOutput) }
            if component.hasOutput {
                Button(store.activity.modes[id] == .chirping ? "Stop test audio" : "Play test audio") {
                    if store.activity.modes[id] == .chirping { store.mesh.stop(); store.activity.clear(id) }
                    else { store.sendAudioTest(to: peer.id, outputID: component.id) }
                }.disabled(!component.isAvailable)
            }
            Divider()
            if component.canMoveBetweenHosts && !away {
                MoveItems(store: store, device: component, hostID: peer.id, hostName: peer.card.name)
                Divider()
            }
            DeviceRoomMenu(store: store, id: id)
    }
}

/// Inputs and outputs sit beneath the host they are attached to: indented, with a guide line from the host's icon.
private struct HostChildren: ViewModifier {
    @Environment(\.stackedLevels) private var stackedLevels
    func body(content: Content) -> some View {
        content.padding(.leading, 36)
            .overlay(alignment: .leading) {
                // Stops beside the last child's icon; stacked rows are taller, so the line ends higher.
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1.5)
                    .padding(.leading, 19).padding(.bottom, stackedLevels ? 64 : 26).accessibilityHidden(true)
            }
    }
}

/// True when the window is too narrow for a slider beside a device's name. One rule for iPhone, iPad and Mac,
/// so the same row looks the same at the same width on every platform.
private struct StackedLevelsKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var stackedLevels: Bool {
        get { self[StackedLevelsKey.self] }
        set { self[StackedLevelsKey.self] = newValue }
    }
}

private var nestedDeviceIndent: CGFloat {
    #if os(iOS)
    12
    #else
    20
    #endif
}

private func roomIncludesRemoteOutput(store: HubStore, key: String, peerID: String, roomID: String) -> Bool {
    let componentIncluded = store.audioMemberships[key]?.contains(roomID) ?? false
    let peerIncluded = store.peerMemberships[peerID]?.contains(roomID) ?? false
    return componentIncluded || peerIncluded
}

private func roomDeviceDropTitle(hovered: Bool) -> String {
    #if os(iOS)
    return "Add device"
    #else
    return hovered ? "Release to add here" : "Add device or drop here"
    #endif
}

private let pageMargin: CGFloat = 20

private let headerTopInset: CGFloat = 8

/// Dark enough for white text; the one colour that means sound is playing.
private let liveGreen = Color(red: 0.10, green: 0.55, blue: 0.27)

/// The grouped-list look from iPhone on both platforms: a tinted canvas with lighter cards on it.
private var canvasColor: Color {
    #if os(macOS)
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1) : NSColor(srgbRed: 0.949, green: 0.949, blue: 0.969, alpha: 1)
    })
    #else
    Color(uiColor: .systemGroupedBackground)
    #endif
}

private var cardColor: Color {
    #if os(macOS)
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : NSColor.white
    })
    #else
    Color(uiColor: .secondarySystemGroupedBackground)
    #endif
}

/// The capsule button used across the home screen: accent-coloured words on a quiet fill, or filled when it is the one thing to do.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.shared(.subheadline, weight: .medium))
            .padding(.horizontal, prominent ? 16 : 12).padding(.vertical, prominent ? 8 : 6)
            .foregroundStyle(prominent ? Color.white : Color.accentColor)
            .background(prominent ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Capsule())
    }
}

extension Font {
    /// One type scale for both platforms. iPhone keeps Dynamic Type; the Mac uses sizes close to
    /// iPhone's defaults instead of its own much smaller text styles.
    static func shared(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        #if os(iOS)
        let font = Font.system(style)
        return weight.map { font.weight($0) } ?? font
        #else
        let sizes: [Font.TextStyle: CGFloat] = [.title2: 21, .title3: 18, .headline: 15, .subheadline: 14, .caption: 12, .caption2: 11]
        return .system(size: sizes[style] ?? 14, weight: weight ?? (style == .headline ? .semibold : .regular))
        #endif
    }
}

private extension View {
    func soundboundPanel() -> some View {
        self.background(cardColor, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.06)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }
}

/// Who is in a room and what each of them may do.
private struct RoomGuestsView: View {
    @ObservedObject var store: HubStore
    let roomID: String
    @ObservedObject private var account = AppleAccount.shared
    @Environment(\.dismiss) private var dismiss
    private var room: AudioRoom? { store.rooms.first { $0.id == roomID } }
    private func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
    private func avatar(_ name: String, tint: Color) -> some View {
        Text(initials(name)).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 38, height: 38).background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.shared(.caption2, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
    private func choice(_ title: String, _ detail: String, policy: JoinPolicy, room: AudioRoom, mine: Bool) -> some View {
        PolicyChoice(title: title, detail: detail, selected: room.policy == policy) {
            var copy = room; copy.policy = policy; store.updateRoom(copy)
        }.disabled(!mine)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let room {
                    let mine = store.canAdminister(room)
                    let holder = room.owner == store.deviceID ? store.name : (store.friends.first(where: { $0.id == room.owner })?.card.name ?? "Paired device")
                    let linked = ([store.name] + store.ownDevices.map(\.card.name)).joined(separator: " · ")
                    let ownerName = mine && !store.ownDevices.isEmpty ? linked : holder
                    let guests = room.guests ?? []
                    let asking = store.requests.filter { $0.roomID == room.id }
                    let invitable = store.friends.filter { peer in
                        peer.id != room.owner && !store.isOwnDevice(peer.id) && !guests.contains { $0.id == peer.id }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("Owner")
                            HStack(spacing: 12) {
                                avatar(mine ? (account.displayName ?? ownerName) : ownerName, tint: liveGreen)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mine ? (account.displayName ?? ownerName) + " (you)" : ownerName).font(.shared(.subheadline, weight: .semibold)).lineLimit(1)
                                    Label(ownerName, systemImage: "desktopcomputer").font(.shared(.caption)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text("Owner").font(.shared(.caption, weight: .semibold)).foregroundStyle(liveGreen)
                                    .padding(.horizontal, 10).padding(.vertical, 4).background(liveGreen.opacity(0.12), in: Capsule())
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("Guests")
                            if guests.isEmpty && asking.isEmpty {
                                Text(mine ? "Nobody else yet. Invite a paired device to listen in, or to help run the room."
                                          : "Only the owner is here.")
                                    .font(.shared(.subheadline)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(guests) { guest in
                                HStack(spacing: 12) {
                                    avatar(guest.name, tint: .purple)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(guest.name + (guest.id == store.deviceID ? " (this device)" : "")).font(.shared(.subheadline, weight: .medium)).lineLimit(1)
                                        Text(guest.role == .control ? "Can add and remove devices" : "Can join and hear the room")
                                            .font(.shared(.caption)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    if mine {
                                        Menu {
                                            ForEach(GuestRole.allCases, id: \.self) { role in
                                                Button { store.setGuest(guest.id, role: role, in: room.id) } label: {
                                                    if guest.role == role { Label(role.rawValue, systemImage: "checkmark") } else { Text(role.rawValue) }
                                                }
                                            }
                                            Divider()
                                            Button("Remove from room", role: .destructive) { store.setGuest(guest.id, role: nil, in: room.id) }
                                        } label: { Text(guest.role.rawValue).font(.shared(.subheadline)) }
                                        .fixedSize().accessibilityLabel("Role for \(guest.name)")
                                    } else {
                                        Text(guest.role.rawValue).font(.shared(.subheadline)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            ForEach(asking) { request in
                                HStack(spacing: 12) {
                                    avatar(request.peer.name, tint: .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(request.peer.name).font(.shared(.subheadline, weight: .medium)).lineLimit(1)
                                        Text("Asked to join").font(.shared(.caption)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Button("Decline") { store.decide(request, approve: false) }.buttonStyle(.bordered).controlSize(.small)
                                    Button("Let in") {
                                        store.decide(request, approve: true)
                                        store.setGuest(request.peer.id, role: .listen, in: room.id)
                                    }.buttonStyle(.borderedProminent).controlSize(.small)
                                }
                            }
                            if mine {
                                Menu {
                                    ForEach(invitable) { peer in
                                        Button(peer.card.name) { store.setGuest(peer.id, role: .listen, in: room.id) }
                                    }
                                    if invitable.isEmpty { Text(store.friends.isEmpty ? "Pair a device first, from Add device" : "Everyone you’ve paired is already here") }
                                } label: {
                                    Label("Invite someone", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 4)
                                }
                                #if os(macOS)
                                .menuStyle(.borderedButton)
                                #else
                                .buttonStyle(.bordered)
                                #endif
                                .padding(.top, 4)
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("Who can find this room")
                            HStack(alignment: .top, spacing: 8) {
                                choice("Invited only", "Hidden from everyone else", policy: .invite, room: room, mine: mine)
                                choice("Friends", "They can ask to join", policy: .friends, room: room, mine: mine)
                                choice("Anyone nearby", "They can ask to join", policy: .request, room: room, mine: mine)
                            }
                        }
                        Text(!mine ? "Only the owner can change who is here."
                             : !store.ownDevices.isEmpty ? "Your devices signed in to the same Apple Account own this room together. Guests are other devices you’ve paired."
                             : "Guests are devices you’ve paired. Sign in with the same Apple Account on your other devices and they will own this room with you.")
                            .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle(room.map { $0.name + " · Guests" } ?? "Guests")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 540, height: 660)
        #endif
    }
}

/// One of the three answers to "who can find this room", used when creating a room and in its Guests sheet.
private struct PolicyChoice: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.shared(.subheadline, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .padding(10).frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NewRoomView: View {
    @ObservedObject var store: HubStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var region = "Home"
    @State private var policy = JoinPolicy.request
    @FocusState private var naming: Bool
    private var ready: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !region.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private func create() {
        guard ready else { return }
        store.addRoom(name: name, region: region, policy: policy)
        dismiss()
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Make a room. Fill it with sound.").font(.shared(.title3, weight: .semibold))
                        Text("A room is the set of speakers and headphones you want playing together.")
                            .font(.shared(.subheadline)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    DetailSection(title: "Name") {
                        TextField("Living room", text: $name)
                            .textFieldStyle(.roundedBorder).focused($naming)
                            .accessibilityLabel("Room name").onSubmit(create)
                        Divider()
                        SettingsRow(title: "Place", caption: "Groups your rooms, like Home or Studio.") {
                            TextField("Home", text: $region).textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180).accessibilityLabel("Region")
                        }
                    }
                    DetailSection(title: "Who can find this room") {
                        HStack(alignment: .top, spacing: 8) {
                            PolicyChoice(title: "Invited only", detail: "Hidden from everyone else", selected: policy == .invite) { policy = .invite }
                            PolicyChoice(title: "Friends", detail: "They can ask to join", selected: policy == .friends) { policy = .friends }
                            PolicyChoice(title: "Anyone nearby", detail: "They can ask to join", selected: policy == .request) { policy = .request }
                        }
                        Label("Joining a room never switches on a microphone.", systemImage: "mic.slash")
                            .font(.shared(.subheadline)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("New room")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create room", action: create).disabled(!ready) }
            }
            .onAppear { naming = true }
        }
        #if os(macOS)
        .frame(width: 540, height: 620)
        #endif
    }
}

private struct DetailPage<Content: View>: View {
    let title: String
    let subtitle: String
    var showHeading = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if showHeading {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 28, weight: .medium, design: .rounded))
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.shared(.subheadline)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                content()
            }
            .padding(28)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.shared(.headline))
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct RoomView: View {
    @ObservedObject var store: HubStore
    let roomID: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    var room: AudioRoom? { store.rooms.first { $0.id == roomID } }
    var body: some View {
        DetailPage(title: room?.name ?? "Room", subtitle: room?.region ?? "") {
            if let room {
                DetailSection(title: "Room settings") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Name").font(.shared(.subheadline)).foregroundStyle(.secondary)
                        TextField("Room name", text: Binding(get: { self.room?.name ?? "" }, set: { var copy = room; copy.name = $0; store.updateRoom(copy) }))
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Who can join?").font(.shared(.subheadline)).foregroundStyle(.secondary)
                        Picker("Who can join?", selection: Binding(get: { self.room?.policy ?? .request }, set: { var copy = room; copy.policy = $0; store.updateRoom(copy) })) {
                            ForEach(JoinPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    Toggle("Omni mode", isOn: Binding(get: { self.room?.omni ?? false }, set: { var copy = room; copy.omni = $0; store.updateRoom(copy) }))
                        .toggleStyle(.switch)
                    Text("Share approved sound with everyone allowed in this room. Microphones stay off until their owners choose to share them.")
                        .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DetailSection(title: "Devices in this room") {
                    if store.deviceRooms.contains(room.id) {
                        Label(store.name, systemImage: HubStore.kind == "mac" ? "laptopcomputer" : "iphone")
                    } else {
                        Text("This device hasn’t joined the room yet.").font(.shared(.subheadline)).foregroundStyle(.secondary)
                        Button("Add this device here") { store.moveDevice(to: room.id) }.buttonStyle(.bordered)
                    }
                }
                DetailSection(title: "Playback level") {
                    HStack { Text("Room volume"); Spacer(); Text("\(Int(room.level * 100))%").monospacedDigit() }
                    Slider(value: Binding(get: { self.room?.level ?? 0.5 }, set: { var copy = room; copy.level = $0; store.updateRoom(copy) }), in: 0...1)
                    Text("Saved for when audio streaming is ready. No sound is playing yet.")
                        .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.navigationTitle("Room")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let room, store.canAdminister(room) {
                HStack {
                    Button("Delete room", role: .destructive) { confirmingDeletion = true }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(20)
                .background(.regularMaterial)
            }
        }
        .alert("Delete room?", isPresented: $confirmingDeletion) {
            Button("Delete room", role: .destructive) {
                store.deleteRoom(roomID)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The devices stay paired. Only this room and its grouping are removed.")
        }
    }
}

private struct DevicesView: View {
    @ObservedObject var store: HubStore
    @AppStorage("SoundboundHub.movable") private var movable = true
    var body: some View {
        DetailPage(title: "Devices", subtitle: "Your devices, wherever you need them.") {
            DetailSection(title: "This device") {
                Label(store.name, systemImage: HubStore.kind == "mac" ? "laptopcomputer" : "iphone").font(.shared(.title3, weight: .medium))
                Toggle("Allow this device to move between rooms", isOn: $movable).toggleStyle(.switch)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Room").font(.shared(.subheadline)).foregroundStyle(.secondary)
                    Picker("Room", selection: Binding(get: { store.deviceRoom ?? "" }, set: { store.moveDevice(to: $0.isEmpty ? nil : $0) })) {
                        Text("Not in a room").tag("")
                        ForEach(store.rooms) { Text("\($0.region) · \($0.name)").tag($0.id) }
                    }.labelsHidden().disabled(!movable)
                }
                Text("Moving rooms never switches on your microphone or starts sharing audio.")
                    .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DetailSection(title: "Paired devices") {
                if store.friends.isEmpty {
                    Text("Add a friend or another device to see it here.").font(.shared(.subheadline)).foregroundStyle(.secondary)
                }
                ForEach(store.friends) { peer in
                    HStack {
                        Label(peer.card.name, systemImage: peer.card.kind == "mac" ? "laptopcomputer" : "iphone")
                        Spacer()
                        Text(store.nearby.contains { $0.id == peer.id } ? "Nearby" : "Not discoverable")
                            .font(.shared(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Devices")
    }
}

private struct FriendsSection: View {
    @ObservedObject var store: HubStore
    @Binding var adding: Bool
    let addFriend: () -> Void
    @ObservedObject private var account = AppleAccount.shared
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2").font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Friends").font(.shared(.subheadline, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(account.isSignedIn
                     ? "Add a friend’s device with a code. Account-wide friends are not connected yet."
                     : "Sign in to connect with people. Your paired hardware appears under Devices.")
                    .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if account.isSignedIn {
                Button(action: addFriend) { Image(systemName: "plus") }
                    .buttonStyle(PillButtonStyle()).accessibilityLabel("Add a friend")
            } else {
                Button("Sign in") { adding = true }
                    .buttonStyle(PillButtonStyle()).accessibilityLabel("Sign in to add friends")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .soundboundPanel()
    }
}

private struct QRCode: View {
    let value: String
    var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let mono = filter.outputImage else { return nil }
        let colors = CIFilter.falseColor()
        colors.inputImage = mono
        colors.color0 = CIColor(red: 1, green: 1, blue: 1)
        colors.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let output = colors.outputImage else { return nil }
        return CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 5, y: 5)), from: output.extent.applying(CGAffineTransform(scaleX: 5, y: 5)))
    }
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(18)
                .accessibilityLabel("Your signed Soundbound invitation QR code")
        }
    }
}

public struct AddFriendView: View {
    @ObservedObject var store: HubStore
    @Environment(\.dismiss) private var dismiss
    @State private var entered = ""
    @State private var scanning = true
    @State private var cameraError: String?
    /// Adding a friend lists nearby people; adding a device lists your own and not-yet-paired devices.
    let people: Bool
    public init(store: HubStore, people: Bool = false) { self.store = store; self.people = people }
    private var shownNearby: [NearbyPeer] {
        store.nearby.filter { peer in
            let own = store.isOwnDevice(peer.id)
            return people ? !own : own || !store.friends.contains { $0.id == peer.id }
        }
    }
    /// Nearby devices, one row each.
    private var nearbyRows: some View {
        ForEach(shownNearby) { peer in
            HStack(spacing: 10) {
                Image(systemName: peer.invitation.peer.kind == "mac" ? "laptopcomputer" : "iphone").frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    // People are listed by their own name, with the device beneath; devices by device name.
                    // The advertised card can be older than the sign-in, so fall back to what a paired device has since told us.
                    let owner = people ? (peer.invitation.peer.owner.map { String($0.prefix(60)) } ?? store.friends.first { $0.id == peer.id }.flatMap { store.ownerName(of: $0) }) : nil
                    Text(owner ?? peer.invitation.peer.name).lineLimit(1)
                    if owner != nil {
                        Text(peer.invitation.peer.name).font(.shared(.caption)).foregroundStyle(Color.black.opacity(0.55)).lineLimit(1)
                    } else {
                        Text(String(peer.id.prefix(8)).uppercased()).font(.caption.monospaced()).foregroundStyle(Color.black.opacity(0.55))
                    }
                }
                Spacer(minLength: 8)
                if store.friends.contains(where: { $0.id == peer.id }) {
                    Label("Paired", systemImage: "checkmark").font(.shared(.caption)).foregroundStyle(Color.black.opacity(0.55))
                } else {
                    Button(store.outgoing.contains(peer.id) ? "Requested" : "Pair") { store.sendRequest(to: peer) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(store.outgoing.contains(peer.id))
                }
            }
        }
    }
    /// Their code, sharing, and nearby discovery, all in the one white panel.
    private var codePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack {
                    TextField("Enter their code", text: $entered)
                        .textFieldStyle(.plain).onSubmit { store.join(codeOrLink: entered) }
                    Button { store.join(codeOrLink: entered) } label: {
                        Image(systemName: "arrow.right.circle.fill").font(.shared(.title2))
                    }
                    .buttonStyle(.plain)
                    .disabled(entered.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send pairing request")
                }.padding(12).background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                ShareLink(item: store.inviteLink) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17))
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Share my code")
            }
            Divider()
            // Opening this sheet is the intent to pair, so there is no switch to find first.
            Text(people ? "Nearby people" : "Nearby devices").font(.shared(.subheadline, weight: .semibold))
            if store.discovering && shownNearby.isEmpty {
                Text("Looking. Open this screen on the other device, on the same network.")
                    .font(.shared(.caption)).foregroundStyle(Color.black.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            } else if !store.discovering {
                Text(store.discoveryStatus).font(.shared(.caption)).foregroundStyle(Color.black.opacity(0.55))
            }
            // A long list scrolls inside the panel instead of pushing the code off the top.
            if shownNearby.count > 3 {
                ScrollView { VStack(alignment: .leading, spacing: 12) { nearbyRows } }.frame(height: 150)
            } else {
                nearbyRows
            }
        }
        .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 22))
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }
    /// The camera (or a plain backdrop until it starts) fills the whole sheet, edge to edge.
    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.20, blue: 0.27), Color(red: 0.28, green: 0.39, blue: 0.43)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // The camera is the background: point it at their code, or let them scan yours.
            if scanning {
                CameraScanner(completion: { value in
                    if let value { scanning = false; entered = value; store.join(codeOrLink: value) }
                }, error: { cameraError = $0 })
            }
        }
    }
    /// Everything sits the same distance from the sheet's edge: Done at the top, the code panel at the bottom.
    private func pairingContent(minHeight: CGFloat) -> some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .buttonStyle(.plain)
            }
            VStack(spacing: 10) {
                QRCode(value: store.nearbyInviteLink).frame(width: 220, height: 220)
                Text(store.friendCode).font(.system(size: 23, weight: .semibold, design: .monospaced)).tracking(3)
                    .foregroundStyle(.white).textSelection(.enabled)
            }
            .padding(.top, 12)
            .accessibilityLabel("Your pairing code, " + store.friendCode)
            if let cameraError {
                Text(cameraError).font(.shared(.caption)).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.45), in: Capsule())
            }
            Spacer(minLength: 0)
            codePanel
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: minHeight)
    }
    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                pairingContent(minHeight: proxy.size.height)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
        }
        #if os(iOS)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        #endif
        .background { backdrop.ignoresSafeArea() }
        .onAppear {
            cameraError = nil; scanning = true
            // Pairing needs each device to see the other, so being here makes this one findable.
            if !store.discovering { store.setDiscovery(true) }
        }
        .onDisappear { scanning = false }
        #if os(macOS)
        .frame(width: 460, height: 680)
        #endif
    }
}

/// A settings line: what it is on the left, the control on the right, an optional explanation beneath.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 12)
                trailing()
            }
            if let caption {
                Text(caption).font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Says which paired devices share this Apple Account, or what to do to link them.
private struct LinkedDevicesNote: View {
    @ObservedObject var store: HubStore
    @ObservedObject private var account = AppleAccount.shared
    var body: some View {
        if account.isSignedIn {
            Divider()
            if !account.canLinkDevices {
                Label("Sign out and sign in again to enable automatic device linking for this installation. You can also connect using Add device.", systemImage: "link.badge.plus")
                    .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.ownDevices.isEmpty {
                Label(store.discovering
                      ? "Looking for your devices automatically. Open Soundbound on your other device and sign in to the same Apple Account on the same local network."
                      : "Turn on Let nearby devices find me to connect your devices automatically.", systemImage: "link")
                    .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Also yours: " + store.ownDevices.map(\.card.name).joined(separator: ", "), systemImage: "link")
                    .font(.shared(.subheadline)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsView: View {
    @State private var showingAudioMap = false
    @ObservedObject var store: HubStore
    @FocusState private var editingName: Bool
    var body: some View {
        DetailPage(title: "Settings", subtitle: "", showHeading: false) {
            DetailSection(title: "Account") {
                AppleAccountView()
                LinkedDevicesNote(store: store)
            }
            DetailSection(title: "This device") {
                SettingsRow(title: "Name") {
                    TextField("Device name", text: $store.name).textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260).focused($editingName)
                        .accessibilityLabel("Device name")
                        .task(id: store.name) {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            if !Task.isCancelled { store.save() }
                        }
                }
                Divider()
                SettingsRow(title: "Fingerprint", caption: "Check that the other device shows the same code when you pair.") {
                    Text(store.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Divider()
                SettingsRow(title: "Let nearby devices find me",
                            caption: "Your name is visible on this local network while this is on. Your Apple Account devices connect automatically; other devices need approval.") {
                    Toggle("Let nearby devices find me", isOn: Binding(get: { store.discovering }, set: { store.setDiscovery($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            DetailSection(title: "Meters") {
                SettingsRow(title: "Meters show",
                            caption: "Amplitude is loudness over time. Frequency is how loud each pitch is, low to high. Your other devices on the same Apple Account follow this choice.") {
                    Picker("Meters show", selection: Binding(get: { store.activity.visualisation },
                                                            set: { store.objectWillChange.send(); store.activity.setVisualisation($0) })) {
                        ForEach(MeterVisualisation.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            DetailSection(title: "Developer") {
                SettingsRow(title: "Show connection diagnostics",
                            caption: "Adds endpoints, interfaces and route tests under paired devices. Diagnostics stay on this device.") {
                    Toggle("Show connection diagnostics", isOn: $store.developerMode)
                        .labelsHidden().toggleStyle(.switch)
                }
                if store.developerMode {
                    Label("Audio map is in the main window, beside the settings button.", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.shared(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Build " + HubStore.appBuildLabel).font(.shared(.caption2)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }.navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // The sheet should open at rest, not with the device name selected for editing.
        .onAppear { DispatchQueue.main.async { editingName = false } }
    }
}

private struct RouteTestControls: View {
    @ObservedObject var monitor: PeerPingMonitor
    let peerID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(monitor.testingRoutes(for: peerID) ? "Testing routes…" : "Test connection routes") { monitor.testRoutes(to: peerID) }
                .disabled(monitor.testingRoutes(for: peerID))
            Text(monitor.routeReport(for: peerID)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}
