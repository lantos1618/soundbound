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
    public init(store: HubStore, localAudioDevices: [LocalAudioDevice] = [], audioMessage: String? = nil,
                onAudioAction: @escaping (LocalAudioAction, String) -> Void = { _, _ in },
                onAudioVolume: @escaping (String, Double) -> Void = { _, _ in }) {
        self.store = store; self.localAudioDevices = localAudioDevices; self.audioMessage = audioMessage
        self.onAudioAction = onAudioAction; self.onAudioVolume = onAudioVolume
    }
    public var body: some View {
        NavigationStack {
            HomeView(store: store, localAudioDevices: localAudioDevices, audioMessage: audioMessage,
                     onAudioAction: onAudioAction, onAudioVolume: onAudioVolume)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ZStack {
                        Text("Soundbound")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        HStack {
                            Spacer()
                            Button { settings = true } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 20))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Settings")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
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
                Text("Choose your headphones").font(.headline)
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
        .onChange(of: scenePhase) { phase in if phase != .active { store.activity.stopRecording() } }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            store.observeAudioDevices(localAudioDevices, now: date)
        }
        .overlay { IncomingAudioApproval(mesh: store.mesh) }
        .overlay(alignment: .bottom) {
            if let notice = store.audioNotice {
                Text(notice).font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
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
                    Text("Allow audio playback?").font(.headline)
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
    @ObservedObject var mesh: AudioMesh
    @ObservedObject var activity: DeviceAudioActivity
    @ObservedObject var roomTest: RoomPlaybackTest
    let localMessage: String?
    private var recording: Bool { activity.modes.values.contains(.recording) }
    private var replaying: Bool { activity.recordedID.map { activity.modes[$0] == .chirping } ?? false }
    private var busy: Bool { recording || replaying || mesh.active || roomTest.active }
    private var message: String {
        if recording || replaying { return activity.message ?? "Audio active" }
        if mesh.active { return mesh.status }
        if roomTest.active { return roomTest.status }
        if let localMessage { return localMessage }
        if let message = activity.message { return message }
        if mesh.status != "No audio shared" { return mesh.status }
        if !roomTest.status.isEmpty { return roomTest.status }
        return ""
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop") {
                if recording { activity.stopRecording() }
                else if replaying { activity.stopPlayback() }
                else if roomTest.active { roomTest.stop() }
                else { mesh.stop() }
            }.buttonStyle(.plain).frame(width: 44).opacity(busy ? 1 : 0)
                .disabled(!busy).accessibilityHidden(!busy)
        }
        .padding(.horizontal, 28).frame(height: 56)
        .background(canvasColor)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct AudioDeviceGlyph: View {
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    let symbol: String
    let name: String
    var input: LocalAudioDevice? = nil
    var enabled = true
    let play: () -> Void
    @GestureState private var contactActive = false
    @State private var pressed = false
    @State private var heldToRecord = false
    @State private var pressToken = UUID()
    private var mode: DeviceAudioActivity.Mode { activity.modes[id] ?? .idle }
    private var color: Color { mode == .recording ? .red : mode == .chirping ? .green : mode == .waiting ? .orange : .secondary }
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(mode == .idle ? 0 : 0.12)).frame(width: 36, height: 36)
            Image(systemName: symbol).font(.system(size: 21)).foregroundStyle(color)
                .scaleEffect(1 + (activity.levels[id] ?? 0) * 0.3)
        }.frame(width: 40, height: 40).contentShape(Circle())
            .animation(.easeOut(duration: 0.08), value: activity.levels[id] ?? 0)
            .opacity(enabled ? 1 : 0.4)
            .gesture(DragGesture(minimumDistance: 0).updating($contactActive) { _, active, _ in active = true }.onChanged { value in
                guard enabled else { return }
                if !pressed {
                    pressed = true; heldToRecord = false
                    let token = UUID(); pressToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        guard pressed, pressToken == token, let input else { return }
                        heldToRecord = true; activity.beginRecording(input)
                    }
                }
                if abs(value.translation.width) + abs(value.translation.height) > 35 {
                    pressed = false; pressToken = UUID(); activity.endRecording(id)
                }
            }.onEnded { _ in
                let shouldPlay = pressed && !heldToRecord && enabled
                pressed = false; pressToken = UUID()
                activity.endRecording(id)
                if shouldPlay { play() }
            })
            .onChange(of: contactActive) { active in
                if !active {
                    DispatchQueue.main.async {
                        if !contactActive { activity.endRecording(id); pressed = false; pressToken = UUID() }
                    }
                }
            }
            .accessibilityElement().accessibilityLabel(name + (mode == .recording ? ", recording" : mode == .chirping ? ", playing" : ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { play() } }
            .accessibilityAction(named: "Start recording") { if let input, enabled { activity.beginRecording(input) } }
            .accessibilityAction(named: "Stop recording") { activity.endRecording(id) }
            .help(input == nil ? "Tap to play a test sound" : "Hold to record; release to stop")
            .onDisappear { activity.endRecording(id) }
    }
}

private struct AudioStateLabel: View {
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    let fallback: String
    var body: some View {
        let mode = activity.modes[id] ?? .idle
        Text(mode == .recording ? "Recording" : mode == .chirping ? "Chirping" : mode == .waiting ? "Awaiting approval" : fallback)
            .font(.caption).foregroundStyle(mode == .recording ? Color.red : mode == .chirping ? .green : mode == .waiting ? .orange : .secondary)
    }
}

private struct RecordingReplayControl: View {
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    private var available: Bool { activity.recordedID == id }
    var body: some View {
        Button("Replay") { activity.playRecording(id) }
            .font(.caption).buttonStyle(.plain).frame(width: 48)
            .opacity(available ? 1 : 0).disabled(!available).accessibilityHidden(!available)
    }
}

private struct DeviceRowText: View {
    let name: String
    let detail: String
    @ObservedObject var activity: DeviceAudioActivity
    let id: String
    let status: String
    var canReplay = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 14, weight: .medium))
                .lineLimit(2, reservesSpace: true).frame(maxWidth: .infinity, alignment: .leading)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                AudioStateLabel(activity: activity, id: id, fallback: status).lineLimit(1)
                Spacer(minLength: 0)
                if canReplay { RecordingReplayControl(activity: activity, id: id) }
            }.frame(height: 18)
        }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
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

private struct LocalAudioRow: View {
    let device: LocalAudioDevice
    @ObservedObject var store: HubStore
    let action: (LocalAudioAction, String) -> Void
    let volumeChanged: (String, Double) -> Void
    @State private var level = 0.5
    @State private var editing = false
    @State private var showingSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DeviceDragHandle(id: "audio:" + device.id, name: device.name)
                AudioDeviceGlyph(activity: store.activity, id: device.id, symbol: device.icon, name: device.name,
                    input: device.hasInput ? device : nil, enabled: device.isAvailable && !device.busy && !store.mesh.active) {
                    if device.hasOutput { action(.testOutput, device.id) }
                    else { store.activity.showRecordingHint(device.id) }
                }
                DeviceRowText(name: device.name,
                    detail: device.connectionLabel + " · " + (device.hasInput && device.hasOutput ? "Input & output" : device.hasInput ? "Microphone" : "Speaker"),
                    activity: store.activity, id: device.id, status: device.status, canReplay: true)
                    .modifier(DeviceDragArea(id: "audio:" + device.id, name: device.name))
                ZStack { if device.busy { ProgressView().controlSize(.small) } }.frame(width: 14, height: 18)
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 24, height: 24)
                }.buttonStyle(.plain)
                    .help("Settings for \(device.name)")
                    .accessibilityLabel("Settings for \(device.name)")

            }
            if device.volume != nil {
                HStack(spacing: 10) {
                    Text("Volume").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $level, in: 0...1) { isEditing in
                        editing = isEditing
                        if !isEditing { volumeChanged(device.id, level) }
                    }
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Volume for \(device.name)").disabled(device.busy)
                    Text("\(Int(level * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    Spacer(minLength: 0)
                }.padding(.leading, 76)
            }
            if device.awaitingTestAnswer {
                HStack {
                    Text("Did you hear it in your headphones?").font(.caption)
                    Button("Yes") { action(.heardSound, device.id) }
                    Button("No") { action(.didNotHearSound, device.id) }
                }
            }
        }
        .padding(.vertical, 10)
        .sheet(isPresented: $showingSettings) {
            AudioDeviceSettingsView(device: device, store: store, action: action)
        }
        .onAppear { level = device.volume ?? 0.5 }
        .onChange(of: device.volume) { value in if !editing { level = value ?? 0.5 } }
        .onChange(of: level) { value in
            if !editing, let actual = device.volume, abs(value - actual) > 0.005 { volumeChanged(device.id, value) }
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
                    Label(device.name, systemImage: device.icon).font(.title3.weight(.medium))
                    Text(device.status).font(.subheadline).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Use this device").font(.headline)
                        if device.hasOutput { Button(device.selectedOutput ? "Selected for this device" : "Use for this device") { request(.useOutput) }.disabled(device.selectedOutput || device.busy) }
                        if device.hasInput { Button(device.selectedInput ? "Selected microphone" : "Use as microphone") { request(.useInput) }.disabled(device.selectedInput || device.busy) }
                        if device.canConnect { Button("Connect here") { request(.connect) }.disabled(device.busy) }
                        if device.canDisconnect { Button("Disconnect here") { request(.disconnect) }.disabled(device.busy) }
                        if device.canTest { Button("Test sound") { action(.testSound, device.id); dismiss() }.disabled(device.busy) }
                    }.buttonStyle(.bordered)
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("When things change").font(.headline)
                        Toggle("Ask before Soundbound switches this device", isOn: setting(\.askBeforeChanges))
                        Toggle("Tell me when its connection or route changes", isOn: setting(\.notifyChanges))
                        Toggle("Remove from room when disconnected", isOn: setting(\.removeWhenDisconnected))
                        Text("Removal waits three seconds for brief dropouts. Apple’s automatic switches can only be detected afterward; these settings cannot block them.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.toggleStyle(.switch)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Room").font(.headline)
                        ForEach(store.rooms) { room in
                            Toggle(room.name, isOn: Binding(
                                get: { store.audioMemberships[device.id]?.contains(room.id) == true },
                                set: { joined in
                                    if joined { store.moveAudioDevice(device.id, to: room.id) }
                                    else { store.removeAudioDevice(device.id, from: room.id) }
                                })).disabled(room.owner != store.deviceID)
                        }
                        Text("A device can belong to more than one room.").font(.caption).foregroundStyle(.secondary)
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
            Text(title).font(.title3.weight(.medium))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }.frame(maxWidth: .infinity).padding(.vertical, 52)
    }
}

private struct HomeDeviceRow: View {
    let name: String
    let owner: String
    let kind: String
    let activity: DeviceAudioActivity
    let activityID: String
    var nearby = false
    var isLocal = false
    var dragID: String? = nil
    var settingsAction: (() -> Void)? = nil
    var testAction: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let dragID { DeviceDragHandle(id: dragID, name: name) }
            AudioDeviceGlyph(activity: activity, id: activityID,
                symbol: kind == "mac" ? "laptopcomputer" : "iphone", name: name,
                enabled: testAction != nil) { testAction?() }
            DeviceRowText(name: name, detail: owner, activity: activity, id: activityID,
                          status: isLocal ? "This device" : (nearby ? "Nearby" : "Offline"))
                .modifier(DeviceDragArea(id: dragID, name: name))
            if let settingsAction {
                Button(action: settingsAction) { Image(systemName: "gearshape").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Settings for \(name)").accessibilityLabel("Settings for \(name)")
            } else { Color.clear.frame(width: 24, height: 24) }
        }.padding(.vertical, 10)
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
    @State private var adding = false
    @State private var roomSettings: AudioRoom?
    @State private var deletingRoom: AudioRoom?
    @State private var showingDeleteConfirmation = false
    @StateObject private var roomTest = RoomPlaybackTest()
    @State private var hoveredRoom: String?
    @State private var overDevices = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if store.identityLoading {
                    Label(Identity.usesDevelopmentFile ? "Loading device identity…" : "Unlock your device identity in the Keychain prompt.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Devices").font(.title2.weight(.medium))
                        Spacer()
                        Button { addingFriend = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).accessibilityLabel("Add a device")
                    }
                    ForEach(store.requests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(request.peer.name) wants to pair").font(.headline)
                            Text("Pairing allows audio playback. It never turns on a microphone.").font(.caption).foregroundStyle(.secondary)
                            Text("Device fingerprint: \(request.peer.id.prefix(8).uppercased())")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Allow") { store.decide(request, approve: true) }.buttonStyle(.borderedProminent)
                                Button("Decline") { store.decide(request, approve: false) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    VStack(spacing: 0) {
                        HomeDeviceRow(name: store.name, owner: "You", kind: HubStore.kind, activity: store.activity, activityID: store.deviceID, nearby: true, isLocal: true, dragID: store.deviceID, settingsAction: { showingDeviceSettings = true }, testAction: testLocalHost)
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { acceptHostDrop($0, hostID: store.deviceID) }
                            .contextMenu {
                                ForEach(store.rooms) { room in
                                    Button("Add to \(room.name)") { store.moveDevice(to: room.id) }
                                }
                                if store.deviceRoom != nil {
                                    Button("Remove from all rooms") { store.moveDevice(to: nil) }
                                }
                            }
                        ForEach(localAudioDevices) { device in
                            Divider().padding(.leading, 76)
                            LocalAudioRow(device: device, store: store, action: onAudioAction, volumeChanged: onAudioVolume)
                                .padding(.leading, nestedDeviceIndent)
                        }
                        ForEach(store.friends) { peer in
                            Divider().padding(.leading, 76)
                            peerRow(peer)
                            ForEach(store.peerAudioDevices[peer.id] ?? []) { component in
                                remoteComponentRow(component, peer: peer)
                                    .padding(.leading, nestedDeviceIndent)
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 4)
                    .overlay(dropOutline(active: overDevices))
                    .contentShape(Rectangle())
                    .onDrop(of: [UTType.plainText], isTargeted: $overDevices) { acceptDrop($0, roomID: nil) }
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Rooms").font(.title2.weight(.medium))
                        Spacer()
                        Button { adding = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).accessibilityLabel("Add a room")
                    }
                    if store.rooms.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("A place for your sound").font(.headline)
                            Text("Tap + beside Rooms to make a place for your devices.").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .soundboundPanel()
                    }
                    ForEach(store.rooms) { room in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                Button { testRoom(room) } label: {
                                    Label(room.name, systemImage: "play.circle").font(.headline)
                                }.buttonStyle(.plain).disabled(roomTest.active)
                                    .help("Play a test on this room’s available speakers")
                                Text(room.owner == store.deviceID ? room.region : "Synced · " + (store.friends.first(where: { $0.id == room.owner })?.card.name ?? "Paired device"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { roomSettings = room } label: { Image(systemName: "gearshape").frame(width: 24, height: 24) }
                                    .buttonStyle(.plain).disabled(room.owner != store.deviceID)
                                    .help(room.owner == store.deviceID ? "Room settings" : "Edit this room on the device that created it")
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Room settings") { roomSettings = room }.disabled(room.owner != store.deviceID)
                                Button("Delete room", role: .destructive) {
                                    deletingRoom = room
                                    showingDeleteConfirmation = true
                                }.disabled(room.owner != store.deviceID)
                            }
                            Divider()
                            VStack(spacing: 0) {
                                if store.deviceRooms.contains(room.id) { roomDeviceRow(stacked: false) }
                                ForEach(localAudioDevices.filter { store.audioDevice($0.id, belongsTo: room.id) }) { device in
                                    if store.deviceRooms.contains(room.id) || localAudioDevices.first(where: { store.audioDevice($0.id, belongsTo: room.id) })?.id != device.id {
                                        Divider().padding(.leading, 76)
                                    }
                                    LocalAudioRow(device: device, store: store, action: onAudioAction, volumeChanged: onAudioVolume)
                                        .padding(.leading, store.deviceRooms.contains(room.id) ? nestedDeviceIndent : 0)
                                }
                                ForEach(store.friends.filter { store.peerMemberships[$0.id]?.contains(room.id) == true }) { peer in
                                    Divider().padding(.leading, 76)
                                    peerRow(peer)
                                    ForEach(store.peerAudioDevices[peer.id] ?? []) { component in
                                        remoteComponentRow(component, peer: peer).padding(.leading, nestedDeviceIndent)
                                    }
                                }
                                ForEach(store.friends.filter { store.peerMemberships[$0.id]?.contains(room.id) != true }) { peer in
                                    ForEach((store.peerAudioDevices[peer.id] ?? []).filter {
                                        store.audioMemberships[HubStore.remoteComponentID(peer: peer.id, component: $0.id)]?.contains(room.id) == true
                                    }) { component in
                                        remoteComponentRow(component, peer: peer)
                                    }
                                }
                            }
                            Label(hoveredRoom == room.id ? "Release to add here" : "Drop a device here", systemImage: "plus")
                                .font(.caption).foregroundStyle(hoveredRoom == room.id ? Color.accentColor : Color.secondary)
                                .padding(12).frame(maxWidth: .infinity)
                                .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                                    hoveredRoom == room.id ? Color.accentColor : Color.secondary.opacity(0.25),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .contextMenu {
                                Button("Room settings") { roomSettings = room }.disabled(room.owner != store.deviceID)
                                Button("Delete room", role: .destructive) {
                                    deletingRoom = room
                                    showingDeleteConfirmation = true
                                }.disabled(room.owner != store.deviceID)
                            }
                            .overlay(dropOutline(active: hoveredRoom == room.id))
                            .contentShape(Rectangle())
                            .onDrop(of: [UTType.plainText], isTargeted: Binding(
                                get: { hoveredRoom == room.id },
                                set: { hoveredRoom = $0 ? room.id : nil }
                            )) { acceptDrop($0, roomID: room.id) }
                    }
                }
                FriendsSection(store: store, adding: $showingDeviceSettings)
            }
            .padding(28).frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(canvasColor)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HomeAudioStatus(mesh: store.mesh, activity: store.activity, roomTest: roomTest, localMessage: audioMessage)
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
        .sheet(isPresented: $addingFriend) { AddFriendView(store: store) }
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
    private func testLocalHost() {
        if let output = localAudioDevices.first(where: { $0.hasOutput && $0.selectedOutput }) { onAudioAction(.testOutput, output.id) }
    }
    private func testRoom(_ room: AudioRoom) {
        var targets: [RoomTestTarget] = localAudioDevices.filter {
            $0.hasOutput && $0.isAvailable && store.audioDevice($0.id, belongsTo: room.id)
        }.map { .local(id: $0.id, name: $0.name) }
        for peer in store.friends where store.nearby.contains(where: { $0.id == peer.id }) {
            let wholeHost = store.peerMemberships[peer.id]?.contains(room.id) == true
            let outputs = (store.peerAudioDevices[peer.id] ?? []).filter {
                $0.hasOutput && $0.isAvailable && (wholeHost || store.audioMemberships[HubStore.remoteComponentID(peer: peer.id, component: $0.id)]?.contains(room.id) == true)
            }
            targets += outputs.map { .remote(peer: peer.id, output: $0.id, name: $0.name) }
            if wholeHost && outputs.isEmpty { targets.append(.remote(peer: peer.id, output: nil, name: peer.card.name)) }
        }
        roomTest.start(targets, store: store) { onAudioAction(.testOutput, $0) }
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
            DispatchQueue.main.async {
                guard store.identity != nil else { return }
                if value == store.deviceID {
                    store.moveDevice(to: roomID)
                } else if value.hasPrefix("audio:") {
                    let id = String(value.dropFirst(6))
                    guard localAudioDevices.contains(where: { $0.id == id }) else { return }
                    store.moveAudioDevice(id, to: roomID)
                } else if value.hasPrefix("remote:") {
                    guard store.friends.contains(where: { peer in
                        (store.peerAudioDevices[peer.id] ?? []).contains {
                            HubStore.remoteComponentID(peer: peer.id, component: $0.id) == value
                        }
                    }) else { return }
                    store.moveAudioDevice(value, to: roomID)
                } else if value.hasPrefix("peer:") {
                    store.movePeer(String(value.dropFirst(5)), to: roomID)
                }
            }
        }
        return true
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
        let id = HubStore.remoteComponentID(peer: peer.id, component: component.id)
        return HStack(spacing: 8) {
            DeviceDragHandle(id: id, name: component.name)
            AudioDeviceGlyph(activity: store.activity, id: id, symbol: component.icon, name: component.name,
                enabled: component.hasOutput && component.isAvailable && !store.mesh.active) {
                store.sendAudioTest(to: peer.id, outputID: component.id)
            }
            DeviceRowText(name: component.name,
                detail: component.connectionLabel + " · " + (component.hasInput && component.hasOutput ? "Input & output" : component.hasInput ? "Microphone" : "Speaker"),
                activity: store.activity, id: id,
                status: component.hasInput && !component.hasOutput ? "Record on " + peer.card.name : component.selectedOutput || component.selectedInput ? "In use" : component.isAvailable ? "Available" : "Not connected")
                .modifier(DeviceDragArea(id: id, name: component.name))
            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.vertical, 10)
        .contextMenu {
            ForEach(store.rooms) { room in
                Button("Add to \(room.name)") { store.moveAudioDevice(id, to: room.id) }
            }
            Button("Remove from all rooms") { store.moveAudioDevice(id, to: nil) }
        }
    }

    private func peerRow(_ peer: KnownPeer) -> some View {
        HomeDeviceRow(name: peer.card.name, owner: "Paired device", kind: peer.card.kind, activity: store.activity, activityID: "peer:" + peer.id,
            nearby: store.nearby.contains { $0.id == peer.id }, dragID: "peer:" + peer.id, testAction: { store.sendAudioTest(to: peer.id) })
            .onDrop(of: [UTType.plainText], isTargeted: nil) { acceptHostDrop($0, hostID: peer.id) }
            .contextMenu {
                ForEach(store.rooms) { room in
                    Button("Add to \(room.name)") { store.movePeer(peer.id, to: room.id) }
                }
                if store.peerRooms[peer.id] != nil {
                    Button("Remove from all rooms") { store.movePeer(peer.id, to: nil) }
                }
            }
    }
    private func roomDeviceRow(stacked: Bool) -> some View {
        HomeDeviceRow(name: store.name, owner: "You", kind: HubStore.kind, activity: store.activity, activityID: store.deviceID,
                      nearby: true, isLocal: true, dragID: store.deviceID, settingsAction: { showingDeviceSettings = true }, testAction: testLocalHost)
    }

}

private var nestedDeviceIndent: CGFloat {
    #if os(iOS)
    12
    #else
    32
    #endif
}

private var canvasColor: Color {
    #if os(macOS)
    Color(nsColor: .windowBackgroundColor)
    #else
    Color(uiColor: .systemGroupedBackground)
    #endif
}

private extension View {
    func soundboundPanel() -> some View {
        self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.05)))
            .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
    }
}

private struct NewRoomView: View {
    @ObservedObject var store: HubStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var region = "Home"
    @State private var policy = JoinPolicy.request
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New room")
                .font(.title2.weight(.medium))
                .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Room name").font(.subheadline.weight(.medium))
                        TextField("For example, Living room", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Room name")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Region").font(.subheadline.weight(.medium))
                        TextField("For example, Home or Studio", text: $region)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Region")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Who can join?").font(.subheadline.weight(.medium))
                        Picker("Who can join?", selection: $policy) {
                            ForEach(JoinPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Joining a room never switches on a microphone.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create room") {
                    store.addRoom(name: name, region: region, policy: policy)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || region.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(20)
        }
        #if os(macOS)
        .frame(width: 440, height: 460)
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
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
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
            Text(title).font(.headline)
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
                        Text("Name").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Room name", text: Binding(get: { self.room?.name ?? "" }, set: { var copy = room; copy.name = $0; store.updateRoom(copy) }))
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Who can join?").font(.subheadline).foregroundStyle(.secondary)
                        Picker("Who can join?", selection: Binding(get: { self.room?.policy ?? .request }, set: { var copy = room; copy.policy = $0; store.updateRoom(copy) })) {
                            ForEach(JoinPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    Toggle("Omni mode", isOn: Binding(get: { self.room?.omni ?? false }, set: { var copy = room; copy.omni = $0; store.updateRoom(copy) }))
                        .toggleStyle(.switch)
                    Text("Share approved sound with everyone allowed in this room. Microphones stay off until their owners choose to share them.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DetailSection(title: "Devices in this room") {
                    if store.deviceRooms.contains(room.id) {
                        Label(store.name, systemImage: HubStore.kind == "mac" ? "laptopcomputer" : "iphone")
                    } else {
                        Text("This device hasn’t joined the room yet.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Add this device here") { store.moveDevice(to: room.id) }.buttonStyle(.bordered)
                    }
                }
                DetailSection(title: "Playback level") {
                    HStack { Text("Room volume"); Spacer(); Text("\(Int(room.level * 100))%").monospacedDigit() }
                    Slider(value: Binding(get: { self.room?.level ?? 0.5 }, set: { var copy = room; copy.level = $0; store.updateRoom(copy) }), in: 0...1)
                    Text("Saved for when audio streaming is ready. No sound is playing yet.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.navigationTitle("Room")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if room?.owner == store.deviceID {
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
                Label(store.name, systemImage: HubStore.kind == "mac" ? "laptopcomputer" : "iphone").font(.title3.weight(.medium))
                Toggle("Allow this device to move between rooms", isOn: $movable).toggleStyle(.switch)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Room").font(.subheadline).foregroundStyle(.secondary)
                    Picker("Room", selection: Binding(get: { store.deviceRoom ?? "" }, set: { store.moveDevice(to: $0.isEmpty ? nil : $0) })) {
                        Text("Not in a room").tag("")
                        ForEach(store.rooms) { Text("\($0.region) · \($0.name)").tag($0.id) }
                    }.labelsHidden().disabled(!movable)
                }
                Text("Moving rooms never switches on your microphone or starts sharing audio.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DetailSection(title: "Paired devices") {
                if store.friends.isEmpty {
                    Text("Add a friend or another device to see it here.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(store.friends) { peer in
                    HStack {
                        Label(peer.card.name, systemImage: peer.card.kind == "mac" ? "laptopcomputer" : "iphone")
                        Spacer()
                        Text(store.nearby.contains { $0.id == peer.id } ? "Nearby" : "Not discoverable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Devices")
    }
}

private struct FriendsSection: View {
    @ObservedObject var store: HubStore
    @Binding var adding: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Friends").font(.title2.weight(.medium))
                Spacer()
                Button { adding = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel("Add a friend")
            }
            Text("Sign in to connect with people. Your paired hardware appears under Devices.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct QRCode: View {
    let value: String
    var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let mono = filter.outputImage else { return nil }
        let colors = CIFilter.falseColor()
        colors.inputImage = mono
        colors.color0 = CIColor(red: 0, green: 0.32, blue: 0.92)
        colors.color1 = CIColor(red: 1, green: 1, blue: 1)
        guard let output = colors.outputImage else { return nil }
        return CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 5, y: 5)), from: output.extent.applying(CGAffineTransform(scaleX: 5, y: 5)))
    }
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(18).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel("Your signed Soundbound invitation QR code")
        }
    }
}

public struct AddFriendView: View {
    @ObservedObject var store: HubStore
    @Environment(\.dismiss) private var dismiss
    @State private var entered = ""
    @State private var scanning = false
    @State private var cameraError: String?
    public init(store: HubStore) { self.store = store }
    private var pairingCard: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.20, blue: 0.27), Color(red: 0.28, green: 0.39, blue: 0.43)], startPoint: .topLeading, endPoint: .bottomTrailing)
            #if os(iOS)
            if scanning {
                CameraScanner(completion: { value in
                    scanning = false
                    if let value { entered = value; store.join(codeOrLink: value) }
                }, error: { cameraError = $0 })
            }
            #endif
            VStack(spacing: 20) {
                VStack(spacing: 5) {
                    Text(scanning ? "Scan their code" : "Show them your code").font(.title2.weight(.semibold))
                    Text(scanning ? "Point your camera at a Soundbound code." : "Pair once to allow playback.").font(.subheadline)
                }.foregroundStyle(.white).multilineTextAlignment(.center)
                #if os(iOS)
                Button(scanning ? "Show my code" : "Scan a code") { scanning.toggle(); cameraError = nil; if scanning { store.setDiscovery(true) } }
                    .buttonStyle(.bordered).tint(.white)
                #endif
                Spacer(minLength: 0)
                if scanning {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                        .frame(height: 250).padding(.horizontal, 10)
                    if let cameraError { Text(cameraError).font(.caption).foregroundStyle(.white) }
                } else {
                    VStack(spacing: 10) {
                        QRCode(value: store.nearbyInviteLink).frame(width: 230, height: 230)
                        Text(store.friendCode).font(.system(size: 23, weight: .semibold, design: .monospaced)).tracking(3)
                            .foregroundStyle(.black).textSelection(.enabled)
                    }
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [9, 7])).padding(-8))
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Device code").font(.headline)
                        Spacer()
                        ShareLink(item: store.inviteLink) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    HStack {
                        TextField("Enter their code", text: $entered)
                            .textFieldStyle(.plain).onSubmit { store.join(codeOrLink: entered) }
                        Button { store.join(codeOrLink: entered) } label: {
                            Image(systemName: "arrow.right.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .disabled(entered.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Send pairing request")
                    }.padding(12).background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 22))
                .foregroundStyle(.black)
            }.padding(22)
        }
        .frame(height: 600).clipShape(RoundedRectangle(cornerRadius: 28))
        .onDisappear { scanning = false }
    }
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    pairingCard
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Discover nearby", isOn: Binding(get: { store.discovering }, set: { store.setDiscovery($0) }))
                        Text(store.discoveryStatus).font(.caption).foregroundStyle(.secondary)
                        if store.discovering && store.nearby.isEmpty {
                            Text("No devices found yet. Open Discover on another device on the same network.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(store.nearby) { peer in
                            HStack {
                                Image(systemName: peer.invitation.peer.kind == "mac" ? "laptopcomputer" : "iphone").frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(peer.invitation.peer.name)
                                    Text(String(peer.id.prefix(8)).uppercased()).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.friends.contains(where: { $0.id == peer.id }) { Text("Paired").font(.caption).foregroundStyle(.secondary) }
                                else {
                                    Button(store.outgoing.contains(peer.id) ? "Requested" : "Request") { store.sendRequest(to: peer) }
                                        .disabled(store.outgoing.contains(peer.id))
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                    Text("Nearby finds Soundbound devices, not everyone around you. This first build pairs over the local network; remote codes will need a signaling service.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
            }.navigationTitle("Add a device")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }

        }
        #if os(macOS)
        .frame(width: 460, height: 720)
        #endif
    }
}

private struct SettingsView: View {
    @ObservedObject var store: HubStore
    var body: some View {
        DetailPage(title: "Settings", subtitle: "", showHeading: false) {
            DetailSection(title: "Account") {
                AppleAccountView()
            }
            DetailSection(title: "Your device") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Name").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Device name", text: $store.name).textFieldStyle(.roundedBorder)
                        .task(id: store.name) {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            if !Task.isCancelled { store.save() }
                        }
                }
                HStack {
                    Text("Fingerprint").foregroundStyle(.secondary)
                    Spacer()
                    Text(store.fingerprint).font(.system(.body, design: .monospaced))
                }
            }
            #if os(iOS)
            DetailSection(title: "Playback requests") {
                PlaybackNotificationSettings()
            }
            #endif
            DetailSection(title: "Paired devices") {
                Toggle("Play audio from paired devices automatically", isOn: $store.automaticPairedPlayback)
                    .toggleStyle(.switch)
                Text("Pairing grants playback permission. Microphones still need an explicit hold or share action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DetailSection(title: "Nearby discovery") {
                Toggle("Let nearby devices find me", isOn: Binding(get: { store.discovering }, set: { store.setDiscovery($0) }))
                    .toggleStyle(.switch)
                Text("Your name is visible on this local network while discovery is on. You still approve every pairing request.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Build " + HubStore.appBuildLabel).font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }.navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
