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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            store.observeAudioDevices(localAudioDevices, now: date)
        }
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

private struct MeshActivity: View {
    @ObservedObject var mesh: AudioMesh
    var body: some View {
        if let incoming = mesh.incoming {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(incoming.name) wants to play audio here.").font(.headline)
                HStack {
                    Button("Allow audio") { mesh.decide(allow: true) }.buttonStyle(.borderedProminent)
                    Button("Decline") { mesh.decide(allow: false) }.buttonStyle(.bordered)
                }
            }
        } else if mesh.active {
            HStack {
                Label(mesh.status, systemImage: "waveform").font(.subheadline)
                Spacer()
                Button("Stop", role: .destructive) { mesh.stop() }
            }
        }
    }
}

private struct AudioMeshPanel: View {
    @ObservedObject var store: HubStore
    @ObservedObject var mesh: AudioMesh
    @State private var selected = ""
    var peers: [NearbyPeer] { store.nearby.filter { peer in store.friends.contains { $0.id == peer.id } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Live audio").font(.title2.weight(.medium))
                Spacer()
                Label("Local Wi-Fi", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }
            if let incoming = mesh.incoming {
                Text("\(incoming.name) wants to play audio here.").font(.headline)
                Text("Only allow devices you trust. Use headphones to avoid feedback.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Allow audio") { mesh.decide(allow: true) }.buttonStyle(.borderedProminent)
                    Button("Decline") { mesh.decide(allow: false) }.buttonStyle(.bordered)
                }
            }
            if mesh.active {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mesh.status).font(.subheadline)
                        Text("\(mesh.packets) audio packets").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop", role: .destructive) { mesh.stop() }.buttonStyle(.bordered)
                }
            } else {
                if !store.discovering {
                    Button("Find paired devices") { store.setDiscovery(true) }.buttonStyle(.bordered)
                }
                if peers.isEmpty {
                    Text("Pair your other device using Add, then turn on Discover on both devices.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Picker("Send microphone to", selection: $selected) {
                        Text("Choose a device").tag("")
                        ForEach(peers) { Text($0.invitation.peer.name).tag($0.id) }
                    }
                    HStack {
                        Button("Send test tone") { store.sendAudioTest(to: selected) }.buttonStyle(.bordered)
                        Button { store.shareMicrophone(to: selected) } label: { Label("Share microphone", systemImage: "mic") }
                            .buttonStyle(.borderedProminent)
                    }.disabled(selected.isEmpty)
                    Text("They must allow playback. Your microphone starts after approval; either device can stop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if mesh.status != "No audio shared" { Text(mesh.status).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 8)
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
                Image(systemName: device.icon).font(.system(size: 21, weight: .regular)).foregroundStyle(.secondary).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.system(size: 14, weight: .medium))
                    Text(device.connectionLabel + " · " + device.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if device.busy { ProgressView().controlSize(.small) }
                Text(device.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 24, height: 24)
                }.buttonStyle(.plain)
                    .help("Settings for \(device.name)")
                    .accessibilityLabel("Settings for \(device.name)")

            }.modifier(DeviceDragArea(id: "audio:" + device.id, name: device.name))
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
    var nearby = false
    var isLocal = false
    var dragID: String? = nil
    var settingsAction: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let dragID { DeviceDragHandle(id: dragID, name: name) }
            Image(systemName: kind == "mac" ? "laptopcomputer" : "iphone")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 14, weight: .medium))
                Text(owner).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(isLocal ? "This device" : (nearby ? "Nearby" : "Offline"))
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            if let settingsAction {
                Button(action: settingsAction) { Image(systemName: "gearshape").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Settings for \(name)").accessibilityLabel("Settings for \(name)")
            } else { Color.clear.frame(width: 24, height: 24) }
        }.padding(.vertical, 10)
            .modifier(DeviceDragArea(id: dragID, name: name))
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
    @State private var testingRoom: AudioRoom?
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
                            Text("Device fingerprint: \(request.peer.id.prefix(8).uppercased())")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Allow") { store.decide(request, approve: true) }.buttonStyle(.borderedProminent)
                                Button("Decline") { store.decide(request, approve: false) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    VStack(spacing: 0) {
                        HomeDeviceRow(name: store.name, owner: "You", kind: HubStore.kind, nearby: true, isLocal: true, dragID: store.deviceID, settingsAction: { showingDeviceSettings = true })
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
                                .padding(.leading, 32)
                        }
                        ForEach(store.friends) { peer in
                            Divider().padding(.leading, 76)
                            peerRow(peer)
                            ForEach(store.peerAudioDevices[peer.id] ?? []) { component in
                                remoteComponentRow(component, peer: peer)
                                    .padding(.leading, 32)
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 4)
                    .overlay(dropOutline(active: overDevices))
                    .contentShape(Rectangle())
                    .onDrop(of: [UTType.plainText], isTargeted: $overDevices) { acceptDrop($0, roomID: nil) }
                }
                if let audioMessage {
                    Text(audioMessage).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                                Text(room.name).font(.headline)
                                Text(room.owner == store.deviceID ? room.region : "Synced · " + (store.friends.first(where: { $0.id == room.owner })?.card.name ?? "Paired device"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    Button("Test sound…") { testingRoom = room }
                                    Button("Room settings") { roomSettings = room }.disabled(room.owner != store.deviceID)
                                    if room.owner == store.deviceID && !store.deviceRooms.contains(room.id) {
                                        Button("Add this device here") { store.moveDevice(to: room.id) }
                                    } else if room.owner == store.deviceID {
                                        Button("Remove this device from room") { store.removeDevice(from: room.id) }
                                    }
                                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                                .menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel("Options for \(room.name)")
                            }
                            Divider()
                            VStack(spacing: 0) {
                                if store.deviceRooms.contains(room.id) { roomDeviceRow(stacked: false) }
                                ForEach(localAudioDevices.filter { store.audioDevice($0.id, belongsTo: room.id) }) { device in
                                    if store.deviceRooms.contains(room.id) || localAudioDevices.first(where: { store.audioDevice($0.id, belongsTo: room.id) })?.id != device.id {
                                        Divider().padding(.leading, 76)
                                    }
                                    LocalAudioRow(device: device, store: store, action: onAudioAction, volumeChanged: onAudioVolume)
                                        .padding(.leading, store.deviceRooms.contains(room.id) ? 32 : 0)
                                }
                                ForEach(store.friends.filter { store.peerMemberships[$0.id]?.contains(room.id) == true }) { peer in
                                    Divider().padding(.leading, 76)
                                    peerRow(peer)
                                    ForEach(store.peerAudioDevices[peer.id] ?? []) { component in
                                        remoteComponentRow(component, peer: peer).padding(.leading, 32)
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
                            .overlay(dropOutline(active: hoveredRoom == room.id))
                            .contentShape(Rectangle())
                            .onDrop(of: [UTType.plainText], isTargeted: Binding(
                                get: { hoveredRoom == room.id },
                                set: { hoveredRoom = $0 ? room.id : nil }
                            )) { acceptDrop($0, roomID: room.id) }
                    }
                }
                MeshActivity(mesh: store.mesh)
                FriendsSection(store: store, adding: $showingDeviceSettings)
            }
            .padding(28).frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(canvasColor)
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
        .sheet(item: $testingRoom) { room in
            RoomAudioTestView(store: store, mesh: store.mesh, room: room,
                              devices: localAudioDevices, action: onAudioAction)
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
            Image(systemName: component.icon).font(.system(size: 21)).foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(component.name).font(.system(size: 14, weight: .medium))
                Text(component.connectionLabel + " · " + peer.card.name + " · " + (component.hasInput && component.hasOutput ? "Input & output" : component.hasInput ? "Microphone" : "Audio output"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(component.selectedOutput || component.selectedInput ? "In use" : component.isAvailable ? "Available" : "Not connected")
                .font(.caption).foregroundStyle(.secondary)
            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.vertical, 10)
        .modifier(DeviceDragArea(id: id, name: component.name))
        .contextMenu {
            ForEach(store.rooms) { room in
                Button("Add to \(room.name)") { store.moveAudioDevice(id, to: room.id) }
            }
            Button("Remove from all rooms") { store.moveAudioDevice(id, to: nil) }
        }
    }

    private func peerRow(_ peer: KnownPeer) -> some View {
        HomeDeviceRow(name: peer.card.name, owner: "Paired device", kind: peer.card.kind,
            nearby: store.nearby.contains { $0.id == peer.id }, dragID: "peer:" + peer.id)
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
        HomeDeviceRow(name: store.name, owner: "You", kind: HubStore.kind,
                      nearby: true, isLocal: true, dragID: store.deviceID, settingsAction: { showingDeviceSettings = true })
    }

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

private struct RoomAudioTestView: View {
    @ObservedObject var store: HubStore
    @ObservedObject var mesh: AudioMesh
    let room: AudioRoom
    let devices: [LocalAudioDevice]
    let action: (LocalAudioAction, String) -> Void
    @StateObject private var recording = RoomSoundTest()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(room.name).font(.title2.weight(.medium))
                    Text("Choose a device for a quiet test tone.").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(devices.filter { $0.hasOutput && store.audioDevice($0.id, belongsTo: room.id) }) { device in
                        HStack {
                            Label(device.name, systemImage: device.icon)
                            Spacer()
                            Button("Test sound") { action(.testOutput, device.id) }.disabled(device.busy || mesh.active || recording.busy)
                        }
                    }
                    ForEach(store.friends.filter { store.peerMemberships[$0.id]?.contains(room.id) == true }) { peer in
                        HStack {
                            Label(peer.card.name, systemImage: peer.card.kind == "mac" ? "laptopcomputer" : "iphone")
                            Spacer()
                            Button("Send test tone") { store.sendAudioTest(to: peer.id) }
                                .disabled(mesh.active || recording.busy || !store.nearby.contains { $0.id == peer.id })
                        }
                    }
                    if mesh.active {
                        Text(mesh.status).font(.caption).foregroundStyle(.secondary)
                        Button("Stop audio", role: .destructive) { mesh.stop() }
                    }
                    Text("Other devices must approve playback. Tests are sent to one device at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    AudioMeshPanel(store: store, mesh: mesh)
                    Text("Check this microphone").font(.headline)
                    Text("Record three seconds, then play it back on this device. Nothing is saved to disk or sent to the room.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button(recording.busy ? "Working…" : "Record 3 seconds") { recording.record() }
                            .disabled(recording.busy || mesh.active)
                        if recording.hasRecording {
                            Button("Play recording here") { recording.play() }.disabled(recording.busy || mesh.active)
                        }
                        if recording.busy { Button("Stop") { recording.stop() } }
                    }.buttonStyle(.bordered)
                    Text(recording.status).font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Room sound test")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onDisappear { recording.clear() }
        }
        #if os(macOS)
        .frame(width: 540, height: 500)
        #endif
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
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 28, weight: .medium, design: .rounded))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    Text(scanning ? "Point your camera at a Soundbound code." : "They scan. You approve.").font(.subheadline)
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
        DetailPage(title: "Settings", subtitle: "Stay in control of what you share.") {
            DetailSection(title: "Account") {
                HStack {
                    Spacer()
                    SignInWithAppleButton(.signIn, onRequest: { _ in }, onCompletion: { _ in })
                        .frame(width: 220, height: 40).disabled(true)
                    Spacer()
                }
                Text("Apple sign-in is coming later. You can pair devices locally without an account.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            DetailSection(title: "Nearby discovery") {
                Toggle("Let nearby devices find me", isOn: Binding(get: { store.discovering }, set: { store.setDiscovery($0) }))
                    .toggleStyle(.switch)
                Text("Your name is visible on this local network while discovery is on. You still approve every pairing request.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.navigationTitle("Settings")
    }
}
