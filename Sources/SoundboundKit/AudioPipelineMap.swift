import SwiftUI

private struct PipelineNode: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let details: String
    let active: Bool
    let x: CGFloat
    let y: CGFloat
}

/// A diagnostic view of configured routes and observed streams. No credentials
/// or audio samples are exposed here.
struct AudioPipelineMapView: View {
    @ObservedObject var store: HubStore
    @ObservedObject private var audio: RoomAudio
    @ObservedObject private var ping: PeerPingMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var roomID = ""
    @State private var selectedNode: String?
    @State private var zoom = 0.8

    init(store: HubStore) {
        self.store = store; self.audio = store.roomAudio; self.ping = store.ping
    }
    private var room: AudioRoom? { store.rooms.first { $0.id == roomID } ?? store.activeRoom ?? store.rooms.first }
    private var targets: [(peer: KnownPeer?, device: LocalAudioDevice)] {
        guard let room else { return [] }
        var result = store.reportedAudioDevices.filter {
            $0.hasOutput && store.audioDevice($0.id, belongsTo: room.id)
        }.map { (peer: Optional<KnownPeer>.none, device: $0) }
        for peer in store.friends {
            result += store.displayedPeerDevices(peer.id).filter {
                $0.hasOutput && (store.peerMemberships[peer.id]?.contains(room.id) == true ||
                    store.audioMemberships[HubStore.remoteComponentID(peer: peer.id, component: $0.id)]?.contains(room.id) == true)
            }.map { (peer: Optional(peer), device: $0) }
        }
        return result
    }
    private var nodes: [PipelineNode] {
        let routes = targets
        let centerY = CGFloat(max(1, routes.count) - 1) * 85 + 85
        let emitting = audio.active && audio.roomID == room?.id
        let incoming = audio.pipelineIncomingSource()
        let sourceName = audio.sharingApplications ? "Application mix" :
            store.reportedAudioDevices.first(where: { $0.id == audio.sourceID })?.name ?? "Local audio source"
        var result = [
            PipelineNode(id: "source", title: emitting ? sourceName : incoming == nil ? sourceName : "Remote audio source", subtitle: emitting ? store.name : incoming?.name ?? store.name, symbol: "app.connected.to.app.below.fill",
                details: emitting ? audio.status : incoming == nil ? "No local source is sending to this room. Remote playback is shown on the output nodes." : "Receiving audio from \(incoming!.name). The remote application name is not included in the audio protocol.",
                active: emitting || incoming != nil, x: 120, y: centerY),
            PipelineNode(id: "pcm", title: "Capture & levels", subtitle: "PCM · 24 kHz · mono · 16-bit", symbol: "waveform",
                details: "Application capture or the selected microphone/test source feeds PCM delivery. Room gain and per-output send gain are applied before delivery. Received audio is not forwarded into capture.",
                active: emitting || incoming != nil, x: 355, y: centerY)
        ]
        for (index, target) in routes.enumerated() {
            let peerID = target.peer?.id
            let transportPeerID = peerID ?? audio.pipelineIncomingSource(outputID: target.device.id)?.id
            let key = peerID.map { HubStore.remoteComponentID(peer: $0, component: target.device.id) } ?? target.device.id
            let online = peerID.map { id in store.nearby.contains { $0.id == id } } ?? true
            let state = audio.pipelineState(peerID: peerID, outputID: target.device.id)
            let playing = store.activity.modes[key] == .chirping
            let y = CGFloat(index) * 170 + 85
            let remote = transportPeerID != nil
            let transport = transportPeerID.flatMap { ping.connectionLabel(for: $0) } ?? (remote ? "No observed connection" : "On this device")
            result += [
                PipelineNode(id: key + ":crypto", title: remote ? "Encrypt" : "Local delivery",
                    subtitle: remote ? "AES-256-GCM" : "In-process PCM", symbol: remote ? "lock.shield" : "arrow.right",
                    details: remote ? "Configured protocol: ephemeral X25519 key agreement, HKDF-SHA256, and separate AES-256-GCM send/receive keys. Signed offers authenticate the peer. Encryption is active only once a stream connects. No key material is displayed." : "This output stays on the same device; there is no network encryption stage.",
                    active: state.connected, x: 590, y: y),
                PipelineNode(id: key + ":network", title: remote ? "Network" : "Local path", subtitle: online ? transport : "Peer offline",
                    symbol: remote ? "network" : "desktopcomputer",
                    details: transportPeerID.map { ping.diagnostics(for: $0) + "\n\n" + ping.label(for: $0) + "\nDiscovery: Bonjour. Media: TCP. Internet relay / TURN is not implemented." } ?? "PCM is delivered directly to the local audio engine. A selected Mac system output can receive application audio directly from macOS.",
                    active: state.connected, x: 825, y: y),
                PipelineNode(id: key + ":render", title: "Receive & render", subtitle: state.label, symbol: "waveform.path",
                    details: "Network streams are authenticated and decrypted, then placed in a bounded adaptive playback buffer before rendering. Buffering and clock-drift correction are per receiver; outputs are not sample-synchronized.\n\n" + state.label,
                    active: state.connected, x: 1060, y: y),
                PipelineNode(id: key + ":output", title: target.device.name,
                    subtitle: (target.peer?.card.name ?? store.name) + " · " + (online ? (playing ? "Playing" : target.device.status) : "Offline"),
                    symbol: target.device.icon,
                    details: "Connection: \(target.device.connectionLabel)\nAvailable: \(online && target.device.isAvailable ? "yes" : "no")\nSoundbound send gain: \(Int(store.audioGain(for: key) * 100))%\n" +
                        (target.device.volume.map { "Hardware volume: \(Int($0 * 100))%\n" } ?? "Hardware volume: not reported\n") +
                        "Output latency: \(target.device.latency?.outputMilliseconds.map { String(format: "%.1f ms", $0) } ?? "not measured")\nSpeaker audibility requires a sound test; a connected stream alone does not prove audible output.",
                    active: playing, x: 1295, y: y)
            ]
        }
        return result
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Room", selection: $roomID) {
                        ForEach(store.rooms) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 300)
                    Spacer()
                    Text("Zoom").font(.caption)
                    Slider(value: $zoom, in: 0.4...1.3).frame(width: 100)
                }
                Text("Select a node for details. Green shows an observed stream or playback; gray shows a configured or unavailable path.")
                    .font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let graph = nodes
                    let height = CGFloat(max(1, targets.count)) * 170
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Canvas { context, _ in
                                guard let source = graph.first, graph.count > 1 else { return }
                                let pcm = graph[1]
                                func connect(_ from: PipelineNode, _ to: PipelineNode) {
                                    var path = Path()
                                    path.move(to: CGPoint(x: from.x + 98, y: from.y))
                                    path.addCurve(to: CGPoint(x: to.x - 98, y: to.y),
                                        control1: CGPoint(x: from.x + 125, y: from.y),
                                        control2: CGPoint(x: to.x - 125, y: to.y))
                                    context.stroke(path, with: .color(to.active ? .green : .secondary.opacity(0.4)), lineWidth: 2)
                                }
                                connect(source, pcm)
                                for start in stride(from: 2, to: graph.count, by: 4) {
                                    connect(pcm, graph[start])
                                    for index in start..<(start + 3) { connect(graph[index], graph[index + 1]) }
                                }
                            }
                            ForEach(graph) { node in
                                Button { selectedNode = node.id } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label(node.title, systemImage: node.symbol).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        Text(node.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }.padding(12).frame(width: 196, height: 112, alignment: .leading)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(node.active ? Color.green : Color.secondary.opacity(0.3), lineWidth: selectedNode == node.id ? 3 : 1))
                                }.buttonStyle(.plain).position(x: node.x, y: node.y)
                            }
                        }.frame(width: 1420, height: height)
                            .scaleEffect(zoom, anchor: .topLeading)
                            .frame(width: 1420 * zoom, height: height * zoom, alignment: .topLeading)
                    }.background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    if let selected = graph.first(where: { $0.id == selectedNode }) {
                        ScrollView { VStack(alignment: .leading, spacing: 6) {
                            Text(selected.title).font(.headline)
                            Text(selected.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 145)
                    }
                }
                if targets.isEmpty { Text("Add an output to this room to see its delivery path.").foregroundStyle(.secondary) }
            }.padding().navigationTitle("Audio map")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { roomID = store.activeRoomID ?? store.rooms.first?.id ?? "" }
        #if os(macOS)
        .frame(minWidth: 850, idealWidth: 1100, minHeight: 580, idealHeight: 750)
        #endif
    }
}
