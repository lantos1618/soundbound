import SwiftUI
import WebKit

/// What the audio map draws. Built from live state and handed to the React Flow page as JSON.
/// Every figure is a measurement the app already holds; nothing here is estimated unless labelled so.
struct AudioMapSnapshot: Codable {
    struct Metric: Codable { var label: String; var value: String; var tone: String? }
    struct Total: Codable { var label: String; var value: String }
    /// Something the viewer can change from the card it belongs to: a slider or a button.
    struct Control: Codable {
        var id: String; var kind: String; var label: String
        var value = 0.0, min = 0.0, max = 0.0
        var unit = ""
        var disabled = false
        /// For a slider that moves between fixed stops: what each stop is called. The value is then the stop's index.
        var stops: [String]? = nil
    }
    struct Node: Codable {
        var id: String
        var kind: String
        var stage: String
        var title: String
        var subtitle: String
        var active: Bool
        var level: [Double]?
        var metrics: [Metric]
        var total: Total?
        var details: String
        var column: Double
        var row: Double
        var controls: [Control]? = nil
    }
    struct Edge: Codable {
        var id: String; var from: String; var to: String; var label: String?; var active: Bool
        /// True for a connection that carries sound both ways, drawn with an arrow at each end.
        var both: Bool? = nil
        /// Which side of each card the line uses when it runs up or down instead of left to right: "top" or "bottom".
        var fromSide: String? = nil
        var toSide: String? = nil
    }
    /// A boundary: a device, the Soundbound app inside it, or the network between devices.
    /// Drawn around its member nodes' measured frames, so it always encloses them whatever their size.
    struct Region: Codable { var id: String; var kind: String; var label: String; var members: [String] }
    var nodes: [Node] = []
    var edges: [Edge] = []
    var regions: [Region] = []
    var empty = ""
    /// "amplitude" or "frequency": how the level bars on the cards should be read.
    var meter = "amplitude"
    /// The shape of what a device publishes about itself. Blocks from a different version are not drawn.
    var version: Int? = AudioMapSnapshot.currentVersion
    static let currentVersion = 3
}

extension HubStore {
    private func milliseconds(_ value: Double?) -> String? { value.map { String(format: "%.1f ms", $0) } }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// What this device tells a paired device about its own pipeline: the same picture, without the controls
    /// (they only work here) and without naming the applications in use unless the other device is this person's own.
    func publishedAudioMap(for peerID: String) -> AudioMapSnapshot {
        var map = audioMapSnapshot(roomID: "", playing: isOwnDevice(peerID) ? playingApplications() : [])
        // Controls travel too, so a device allowed to change this one's settings can draw them. Buttons that only
        // make sense here (retesting this device's routes) stay behind.
        for index in map.nodes.indices {
            map.nodes[index].details = ""
            map.nodes[index].controls = map.nodes[index].controls?.filter { !$0.id.hasPrefix("retest:") }
        }
        return map
    }
    /// The whole picture, built the same way for every device: each device describes only itself (what it sends,
    /// what it plays, and what it expects to receive), this device included. The blocks are stacked, the network
    /// between them is one shared region, and a line is drawn from a sender's network card to the matching
    /// receive card inside the receiving device. Nothing about another device is assumed here, so a new device
    /// appears as soon as it is paired and nearby.
    func fullAudioMap(roomID: String, playing: [String] = [], now: Date = Date()) -> AudioMapSnapshot {
        let mine = audioMapSnapshot(roomID: roomID, playing: playing)
        guard !mine.nodes.isEmpty else { return mine }
        var blocks: [(id: String, label: String, map: AudioMapSnapshot, trusted: Bool)] = [(deviceID, name + " · this device", mine, true)]
        for peer in friends.sorted(by: { $0.card.name < $1.card.name }) {
            guard let entry = peerMaps[peer.id], entry.map.version == AudioMapSnapshot.currentVersion,
                  entry.map.nodes.count <= 120, entry.map.edges.count <= 240 else { continue }
            // A device that has stopped answering (asleep, or its app is in the background) keeps its last-known
            // block, greyed and labelled, rather than vanishing from the picture.
            let quiet = now.timeIntervalSince(entry.received) > 6 || !nearby.contains { $0.id == peer.id }
            var theirs = entry.map
            if quiet {
                for index in theirs.nodes.indices { theirs.nodes[index].active = false; theirs.nodes[index].level = theirs.nodes[index].level.map { _ in [] } }
                for index in theirs.edges.indices { theirs.edges[index].active = false }
            }
            // Another device's sliders appear only where this device may change them, and never while it is silent.
            let tunable = !quiet && mayTune(peer.id)
            for index in theirs.nodes.indices {
                theirs.nodes[index].controls = tunable ? theirs.nodes[index].controls?.map { control in
                    var copy = control; copy.id = "peer:" + peer.id + "|" + control.id; return copy
                } : nil
            }
            blocks.append((peer.id, peer.card.name + (isOwnDevice(peer.id) ? " · yours" : " · " + (ownerName(of: peer) ?? "paired")) + (quiet ? " · not answering" : ""), theirs, false))
        }
        return HubStore.joinAudioMaps(blocks, roomID: roomID, meter: mine.meter)
    }
    /// Joins what each device said about itself into one picture. `trusted` is this device's own block; the others
    /// came over the network and are bounded and stripped of controls here.
    static func joinAudioMaps(_ blocks: [(id: String, label: String, map: AudioMapSnapshot, trusted: Bool)],
                              roomID: String, meter: String) -> AudioMapSnapshot {
        var map = AudioMapSnapshot()
        map.meter = meter
        let kinds: Set<String> = ["source", "stage", "output"]
        func clip(_ text: String, _ limit: Int = 120) -> String { String(text.prefix(limit)) }
        var network: [String] = [], offset = 0.0
        var order: [String: Int] = [:], bottoms: [Double] = []
        /// Per device: the local ids it kept, and which of them are active.
        var kept: [String: [String: Bool]] = [:]
        for block in blocks {
            let prefix = "dev:" + block.id + "/"
            // A peer describes every room; keep the chosen room's cards and whatever hardware or network card they lead to.
            var wanted = Set(block.map.nodes.map(\.id))
            if !block.trusted, !roomID.isEmpty {
                wanted = Set(block.map.nodes.map(\.id).filter { $0 == "source" || $0 == "capture" || $0.contains(roomID) })
                for _ in 0..<2 {
                    for edge in block.map.edges where wanted.contains(edge.from) || wanted.contains(edge.to) {
                        for end in [edge.from, edge.to] where end.hasPrefix("hw:") || end.hasPrefix("link:") || end.hasPrefix("net|") { wanted.insert(end) }
                    }
                }
            }
            var ids: [String: Bool] = [:], device: [String] = [], app: [String] = [], bottom = 0.0
            for node in block.map.nodes where wanted.contains(node.id) {
                guard node.id.count <= 400, kinds.contains(node.kind), node.row.isFinite, node.column.isFinite,
                      (0...200).contains(node.row), (0...12).contains(node.column) else { continue }
                var copy = node
                copy.id = prefix + node.id; copy.row += offset
                if !block.trusted {
                    copy.details = ""
                    copy.controls = node.controls.map { $0.prefix(6).filter { $0.id.count <= 200 && $0.value.isFinite && $0.min.isFinite && $0.max.isFinite }.map {
                        var control = $0
                        control.label = clip($0.label, 40); control.unit = clip($0.unit, 8); control.kind = $0.kind == "slider" ? "slider" : "button"
                        control.stops = $0.stops.map { $0.prefix(12).map { clip($0, 12) } }
                        return control
                    } }
                    copy.stage = clip(node.stage, 40); copy.title = clip(node.title); copy.subtitle = clip(node.subtitle)
                    copy.level = node.level.map { $0.prefix(64).map { $0.isFinite ? min(1, max(0, $0)) : 0 } }
                    copy.metrics = node.metrics.prefix(8).map { .init(label: clip($0.label, 60), value: clip($0.value, 80), tone: $0.tone.map { clip($0, 8) }) }
                    copy.total = node.total.map { .init(label: clip($0.label, 60), value: clip($0.value, 40)) }
                }
                map.nodes.append(copy); ids[node.id] = node.active; bottom = max(bottom, node.row)
                if node.id.hasPrefix("net|") { network.append(copy.id) }
                else { device.append(copy.id); if node.column <= 5 { app.append(copy.id) } }
            }
            for edge in block.map.edges where ids[edge.from] != nil && ids[edge.to] != nil && edge.id.count <= 900 {
                map.edges.append(.init(id: prefix + edge.id, from: prefix + edge.from, to: prefix + edge.to,
                                       label: edge.label.map { clip($0, 40) }, active: edge.active, both: edge.both))
            }
            if !device.isEmpty { map.regions.append(.init(id: prefix + "device", kind: "device", label: block.label, members: device)) }
            if !app.isEmpty { map.regions.append(.init(id: prefix + "app", kind: "app", label: "Soundbound", members: app)) }
            kept[block.id] = ids
            order[block.id] = bottoms.count; bottoms.append(offset + bottom)
            // Leave room under each device for the network cards that join it to the next one.
            offset += bottom + 2.5
        }
        // Two devices that talk to each other each describe the stretch of network between them. Draw it once:
        // both connections meet at the same card, placed between the two devices.
        for (first, ids) in kept {
            for local in ids.keys where local.hasPrefix("net|") {
                let second = String(local.dropFirst(4))
                guard first < second, kept[second]?["net|" + first] != nil else { continue }
                let keep = "dev:" + first + "/" + local, drop = "dev:" + second + "/net|" + first
                guard let keepIndex = map.nodes.firstIndex(where: { $0.id == keep }),
                      let dropIndex = map.nodes.firstIndex(where: { $0.id == drop }) else { continue }
                map.nodes[keepIndex].row = (map.nodes[keepIndex].row + map.nodes[dropIndex].row) / 2
                map.nodes[keepIndex].active = map.nodes[keepIndex].active || map.nodes[dropIndex].active
                map.nodes.remove(at: dropIndex)
                for index in map.edges.indices where map.edges[index].to == drop { map.edges[index].to = keep }
                network.removeAll { $0 == drop }
            }
        }
        // Lay the network out by shortest path: each stretch of network sits in the gap directly under the upper
        // of the two devices it joins, in line with their connection cards, so the lines run straight down and up.
        var gaps: [Int: [String]] = [:]
        for id in network {
            guard let index = map.nodes.firstIndex(where: { $0.id == id }) else { continue }
            let ends = map.edges.filter { $0.to == id }.compactMap { edge -> Int? in
                guard edge.from.hasPrefix("dev:"), let slash = edge.from.firstIndex(of: "/") else { return nil }
                return order[String(edge.from[edge.from.index(edge.from.startIndex, offsetBy: 4)..<slash])]
            }
            guard let upper = ends.min() else { continue }
            map.nodes[index].row = bottoms[upper] + 1.25
            map.nodes[index].column = 4 + 1.5 * Double(gaps[upper]?.count ?? 0)
            gaps[upper, default: []].append(id)
            for edgeIndex in map.edges.indices where map.edges[edgeIndex].to == id {
                let from = map.edges[edgeIndex].from
                guard let slash = from.firstIndex(of: "/"),
                      let block = order[String(from[from.index(from.startIndex, offsetBy: 4)..<slash])] else { continue }
                map.edges[edgeIndex].fromSide = block <= upper ? "bottom" : "top"
                map.edges[edgeIndex].toSide = block <= upper ? "top" : "bottom"
            }
        }
        for (gap, members) in gaps.sorted(by: { $0.key < $1.key }) {
            map.regions.append(.init(id: "network:\(gap)", kind: "network", label: "Local network · direct, no relay", members: members))
        }
        return map
    }
    /// This device's own part of the map, and nothing else: what it sends, what it plays, and what it is ready
    /// to receive from each nearby paired device. Every device builds this about itself; `fullAudioMap` joins them.
    /// Every room at once when `roomID` is empty, otherwise just that room.
    /// `playing` names the applications currently making sound here, shared or not.
    func audioMapSnapshot(roomID: String, playing: [String] = []) -> AudioMapSnapshot {
        typealias Metric = AudioMapSnapshot.Metric
        var map = AudioMapSnapshot()
        map.meter = activity.visualisation.rawValue
        let shown = roomID.isEmpty ? rooms : rooms.filter { $0.id == roomID }
        guard !shown.isEmpty else {
            map.empty = "Make a room and add a speaker to see how sound travels."
            return map
        }
        let audio = roomAudio
        let sendingNow = audio.active
        let sourceName = audio.sharingApplications ? "Application mix"
            : reportedAudioDevices.first(where: { $0.id == audio.sourceID })?.name ?? "Not shared to a room"
        let heard = playing.isEmpty ? "nothing" : playing.prefix(4).joined(separator: ", ") + (playing.count > 4 ? " +\(playing.count - 4)" : "")
        // A device set to send only has no receive cards; one set to receive only has nothing leaving it.
        let maySend = audioDirection.sends, mayReceive = audioDirection.receives
        let senders = mayReceive ? friends.filter { peer in nearby.contains { $0.id == peer.id } } : []
        func limitControls() -> [AudioMapSnapshot.Control] {
            [.init(id: "floor", kind: "slider", label: "Starts at", value: Double(AudioBufferPolicy.initialPlaybackFrames / 24), min: 5, max: 40, unit: "ms"),
             .init(id: "ceiling", kind: "slider", label: "Grows to", value: Double(AudioBufferPolicy.maximumTargetFrames / 24), min: 10, max: 70, unit: "ms"),
             .init(id: "reset", kind: "button", label: "Reset to \(AudioBufferPolicy.defaultFloorMilliseconds) and \(AudioBufferPolicy.defaultCeilingMilliseconds) ms")]
        }

        var row = 0.0
        var hardwareRow: [String: Double] = [:], linkRows: [String: [Double]] = [:], linkActive: [String: Bool] = [:]
        var roomRow: [(id: String, first: Double, last: Double)] = []
        for room in shown {
            let first = row
            let live = activeRoomID == room.id
            let sending = sendingNow && audio.roomID == room.id
            let isCurrent = sending || (!sendingNow && live)
            let roomNode = "room:" + room.id, prefix = room.id + "|"
            let outputs = reportedAudioDevices.filter { $0.hasOutput && audioDevice($0.id, belongsTo: room.id) }

            // Sound this device sends to its own speakers.
            for device in outputs where maySend {
                let state = isCurrent ? audio.pipelineState(peerID: nil, outputID: device.id) : (label: "Room is off", connected: false)
                let buffer = AudioPlaybackMetrics.snapshot(id: device.id, systemID: device.systemOutputID)
                let playout = prefix + device.id + ":playout", hardware = "hw:" + device.id
                let direct = state.label == "macOS system output"
                map.nodes.append(.init(id: playout, kind: "stage", stage: "Playout", title: direct ? "Played by macOS" : "Playout buffer",
                    subtitle: state.label, active: state.connected, level: nil,
                    metrics: direct ? [Metric(label: "Buffer", value: "none in Soundbound", tone: "none")] : [
                        Metric(label: "Queued audio", value: milliseconds(buffer?.queuedMilliseconds) ?? "idle", tone: buffer == nil ? "none" : nil),
                        Metric(label: "Buffer target", value: milliseconds(buffer?.targetMilliseconds) ?? "—", tone: buffer == nil ? "none" : nil),
                        Metric(label: "Underruns (session)", value: buffer.map { "\($0.recoveries)" } ?? "—", tone: (buffer?.recoveries ?? 0) > 0 ? "warn" : nil)],
                    details: "", column: 5, row: row, controls: direct ? nil : limitControls()))
                map.edges.append(.init(id: (direct ? "source" : roomNode) + ">" + playout, from: direct ? "source" : roomNode, to: playout,
                    label: direct ? "original app audio" : "gain " + percent(audioGain(for: device.id)), active: state.connected))
                if hardwareRow[device.id] == nil { hardwareRow[device.id] = row }
                map.edges.append(.init(id: playout + ">" + hardware, from: playout, to: hardware,
                                       label: milliseconds(buffer?.queuedMilliseconds).map { "queued " + $0 }, active: state.connected))
                row += 1
            }
            // Sound this device sends to speakers on other devices: encrypted here, then out through the network.
            for peer in friends where maySend {
                for device in displayedPeerDevices(peer.id) where device.hasOutput && (peerMemberships[peer.id]?.contains(room.id) == true ||
                    audioMemberships[HubStore.remoteComponentID(peer: peer.id, component: device.id)]?.contains(room.id) == true) {
                    let key = HubStore.remoteComponentID(peer: peer.id, component: device.id)
                    let state = isCurrent ? audio.pipelineState(peerID: peer.id, outputID: device.id) : (label: "Room is off", connected: false)
                    let encrypt = prefix + key + ":encrypt", link = "link:" + peer.id
                    map.nodes.append(.init(id: encrypt, kind: "stage", stage: "Encrypt", title: "AES-256-GCM",
                        subtitle: "for " + device.name + " · " + state.label, active: state.connected, level: nil,
                        metrics: [Metric(label: "Key agreement", value: "X25519"), Metric(label: "Send gain", value: percent(audioGain(for: key)))],
                        details: "", column: 3, row: row))
                    map.edges.append(.init(id: roomNode + ">" + encrypt, from: roomNode, to: encrypt, label: "send " + percent(audioGain(for: key)), active: state.connected))
                    map.edges.append(.init(id: encrypt + ">" + link, from: encrypt, to: link, label: nil, active: state.connected))
                    linkRows[peer.id, default: []].append(row)
                    linkActive[peer.id] = (linkActive[peer.id] ?? false) || state.connected
                    row += 1
                }
            }
            // Sound this device is ready to play from each nearby paired device, one card per sender and speaker.
            for device in outputs {
                let incoming = audio.pipelineIncomingSource(outputID: device.id)
                for sender in senders {
                    let receiving = incoming?.id == sender.id && (live || activeRoomID == nil)
                    let buffer = receiving ? AudioPlaybackMetrics.snapshot(id: device.id, systemID: device.systemOutputID) : nil
                    let receive = "recv|" + sender.id + "|" + room.id + "|" + device.id
                    map.nodes.append(.init(id: receive, kind: "stage", stage: "Receive", title: "Decrypt and buffer",
                        subtitle: "from " + sender.card.name + " · " + (receiving ? "receiving" : "nothing arriving"), active: receiving, level: nil,
                        metrics: [Metric(label: "Queued audio", value: milliseconds(buffer?.queuedMilliseconds) ?? "idle", tone: buffer == nil ? "none" : nil),
                                  Metric(label: "Buffer target", value: milliseconds(buffer?.targetMilliseconds) ?? "—", tone: buffer == nil ? "none" : nil),
                                  Metric(label: "Underruns (session)", value: buffer.map { "\($0.recoveries)" } ?? "—", tone: (buffer?.recoveries ?? 0) > 0 ? "warn" : nil)],
                        details: "", column: 5, row: row))
                    if hardwareRow[device.id] == nil { hardwareRow[device.id] = row }
                    // Everything from another device arrives through this app's connection to it.
                    map.edges.append(.init(id: "link>" + receive, from: "link:" + sender.id, to: receive, label: nil, active: receiving))
                    linkRows[sender.id, default: []].append(row)
                    linkActive[sender.id] = (linkActive[sender.id] ?? false) || receiving
                    map.edges.append(.init(id: receive + ">hw", from: receive, to: "hw:" + device.id,
                                           label: milliseconds(buffer?.queuedMilliseconds).map { "queued " + $0 }, active: receiving))
                    row += 1
                }
            }
            if row == first { row += 1 } // An empty room still takes a row so it can be seen.
            roomRow.append((room.id, first, row - 1))

            let count = outputs.count + friends.reduce(0) { total, peer in
                total + displayedPeerDevices(peer.id).filter { $0.hasOutput && (peerMemberships[peer.id]?.contains(room.id) == true ||
                    audioMemberships[HubStore.remoteComponentID(peer: peer.id, component: $0.id)]?.contains(room.id) == true) }.count }
            let holder = room.owner == deviceID ? name : friends.first(where: { $0.id == room.owner })?.card.name ?? "paired device"
            map.nodes.append(.init(id: roomNode, kind: "stage", stage: "Room", title: room.name,
                subtitle: live ? (sending ? "Live · sending" : "Live on this device") : "Off on this device",
                active: sending, level: nil,
                metrics: [Metric(label: "Outputs", value: "\(count)", tone: count == 0 ? "none" : nil),
                          Metric(label: "Room gain", value: percent(room.level)),
                          Metric(label: "Guests", value: "\(room.guests?.count ?? 0)"),
                          Metric(label: "Held on", value: holder)],
                details: "", column: 2, row: (first + row - 1) / 2))
            map.edges.append(.init(id: "capture>" + roomNode, from: "capture", to: roomNode, label: sending ? "sending" : nil, active: sending))
        }
        let middle = (row - 1) / 2

        // One card per speaker on this device, however many rooms or senders feed it.
        for device in reportedAudioDevices {
            guard let at = hardwareRow[device.id] else { continue }
            let playingNow = activity.modes[device.id] == .chirping
            let latency = device.latency
            let buffer = AudioPlaybackMetrics.snapshot(id: device.id, systemID: device.systemOutputID)
            let parts = [buffer?.queuedMilliseconds, latency?.outputMilliseconds, latency?.ioBufferMilliseconds].compactMap { $0 }
            map.nodes.append(.init(id: "hw:" + device.id, kind: "output", stage: "Hardware", title: device.name,
                subtitle: playingNow ? "Playing" : device.status, active: playingNow, level: activity.barHeights(device.id),
                metrics: [Metric(label: "OS output latency", value: milliseconds(latency?.outputMilliseconds) ?? "not reported", tone: latency?.outputMilliseconds == nil ? "none" : nil),
                          Metric(label: "I/O buffer", value: milliseconds(latency?.ioBufferMilliseconds) ?? "not reported", tone: latency?.ioBufferMilliseconds == nil ? "none" : nil),
                          Metric(label: "Soundbound gain", value: percent(audioGain(for: device.id))),
                          Metric(label: "Hardware volume", value: device.volume.map(percent) ?? "not reported", tone: device.volume == nil ? "none" : nil)],
                total: parts.isEmpty ? nil : .init(label: "Delay on this device, at least", value: String(format: "%.0f ms", parts.reduce(0, +))),
                details: "", column: 6, row: at))
        }
        // One connection card inside the app for each device this one talks to, in either direction, and the stretch
        // of network that connection crosses. A relay or other hop would be another card here; none exists yet.
        for peer in friends {
            guard let rows = linkRows[peer.id], !rows.isEmpty else { continue }
            let at = rows.reduce(0, +) / Double(rows.count)
            let online = nearby.contains { $0.id == peer.id }, connected = linkActive[peer.id] ?? false
            let trip = ping.roundTrip(for: peer.id)
            let tone = trip.map { $0.milliseconds < 20 ? "good" : $0.milliseconds < 80 ? "warn" : "bad" }
            let link = "link:" + peer.id, network = "net|" + peer.id
            map.nodes.append(.init(id: link, kind: "stage", stage: "Network adapter", title: "Connection to " + peer.card.name,
                subtitle: ping.connectionLabel(for: peer.id) ?? "No observed connection", active: connected, level: nil,
                metrics: [Metric(label: "Discovery", value: "Bonjour"), Metric(label: "Media", value: "TCP · encrypted"),
                          Metric(label: trip?.live == true ? "Round trip (live stream)" : "Round trip (idle probe)",
                                 value: milliseconds(trip?.milliseconds) ?? "not measured", tone: tone ?? "none")],
                details: "", column: 4, row: at,
                controls: online ? [.init(id: "retest:" + peer.id, kind: "button",
                    label: ping.testingRoutes(for: peer.id) ? "Testing routes…" : "Retest routes", disabled: ping.testingRoutes(for: peer.id))] : nil))
            map.nodes.append(.init(id: network, kind: "stage", stage: "Network", title: online ? "Local network" : "Peer offline",
                subtitle: name + " ↔ " + peer.card.name, active: connected, level: nil,
                metrics: [Metric(label: "Path", value: "direct"),
                          Metric(label: "One way, estimated", value: milliseconds(trip.map { $0.milliseconds / 2 }) ?? "—", tone: trip == nil ? "none" : nil),
                          Metric(label: "Relay", value: "none")],
                details: "", column: 7.7, row: at))
            map.edges.append(.init(id: link + ">" + network, from: link, to: network,
                                   label: milliseconds(trip?.milliseconds).map { "RTT " + $0 }, active: connected, both: true))
        }

        // Source and capture: what this device itself puts into a room.
        map.nodes.append(.init(id: "source", kind: "source", stage: "Source", title: sourceName,
            subtitle: sendingNow ? audio.status : maySend ? "Nothing is being sent to a room" : "This device is set to receive only",
            active: sendingNow, level: sendingNow ? activity.barHeights(audio.sourceID ?? "") : activity.barHeights(HubStore.monitorLevelID),
            metrics: [Metric(label: "Kind", value: audio.sharingApplications ? "Mac app audio" : sendingNow ? "Microphone or test" : "—", tone: sendingNow ? nil : "none"),
                      Metric(label: "Making sound here", value: heard, tone: playing.isEmpty ? "none" : "good"),
                      Metric(label: "Sent to", value: sendingNow ? (rooms.first { $0.id == audio.roomID }?.name ?? "a room") : "no room", tone: sendingNow ? "good" : "none")],
            details: "", column: 0, row: middle))
        map.nodes.append(.init(id: "capture", kind: "stage", stage: "Capture", title: "PCM capture",
            subtitle: "24 kHz · mono · 16-bit", active: sendingNow, level: nil,
            metrics: [Metric(label: "Packet size", value: "≤ \(AudioBufferPolicy.packetLabel(frames: AudioBufferPolicy.capturePacketFrames)) · \(AudioBufferPolicy.capturePacketBytes) B")],
            details: "", column: 1, row: middle,
            controls: [.init(id: "capturePacket", kind: "slider", label: "Packet limit",
                value: Double(AudioBufferPolicy.capturePacketStops.lastIndex { $0 <= AudioBufferPolicy.capturePacketFrames } ?? 2),
                min: 0, max: Double(AudioBufferPolicy.capturePacketStops.count - 1),
                stops: AudioBufferPolicy.capturePacketStops.map { AudioBufferPolicy.packetLabel(frames: $0) })]))
        map.edges.append(.init(id: "source>capture", from: "source", to: "capture", label: nil, active: sendingNow))
        return map
    }
}

/// The map as a place in the main window, not a sheet: it fills the area below the header.
struct AudioMapPane: View {
    @ObservedObject var store: HubStore
    @ObservedObject private var audio: RoomAudio
    @ObservedObject private var ping: PeerPingMonitor
    @ObservedObject private var activity: DeviceAudioActivity
    /// Empty means every room.
    @State private var roomID = ""
    @State private var tick = 0
    @State private var playing: [String] = []
    init(store: HubStore) {
        self.store = store; audio = store.roomAudio; ping = store.ping; activity = store.activity
    }
    private var json: String {
        let snapshot = store.fullAudioMap(roomID: roomID, playing: playing)
        guard let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
    private func legend(_ color: Color, _ text: String, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 10)
            Text(text).font(.shared(.caption)).foregroundStyle(.secondary)
        }
    }
    /// A slider or button on one of the map's cards.
    private func control(_ id: String, _ value: Double) {
        if id.hasPrefix("peer:"), let bar = id.firstIndex(of: "|") {
            // A control on another device's card: ask that device to make the change.
            store.sendTuning(to: String(id[id.index(id.startIndex, offsetBy: 5)..<bar]), control: String(id[id.index(after: bar)...]), value: value)
        } else if id.hasPrefix("retest:") { ping.testRoutes(to: String(id.dropFirst(7))) }
        else { _ = store.applyTuning(id, value) }
        tick &+= 1
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("Rooms shown", selection: $roomID) {
                    Text("All rooms").tag("")
                    ForEach(store.rooms) { Text($0.name).tag($0.id) }
                }.labelsHidden().fixedSize()
                Spacer(minLength: 8)
                legend(.secondary, "Device")
                legend(.accentColor, "Soundbound")
                legend(.orange, "Network", dashed: true)
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 0.10, green: 0.55, blue: 0.27)).frame(width: 8, height: 8)
                    Text("Sound moving").font(.shared(.caption)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            AudioMapWebView(json: json, tick: tick, onControl: control)
        }
        .onAppear {
            playing = store.playingApplications(); store.onLevelMonitor?(true)
            // Ask paired devices for their own pipelines, now and once a second while the map is open.
            store.audioMapOpen = true; store.lastInventoryRefresh = .distantPast; store.inventoryPending.removeAll()
            #if os(iOS)
            // A sleeping phone stops answering other devices, so stay awake while the map is on screen.
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onDisappear {
            store.onLevelMonitor?(false); store.audioMapOpen = false; store.peerMaps.removeAll()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        // Meters and buffers move faster than the published state that redraws this view.
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in tick &+= 1 }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in playing = store.playingApplications() }
    }
}

private final class AudioMapCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var ready = false
    var pending = "{}"
    weak var view: WKWebView?
    var onControl: (String, Double) -> Void = { _, _ in }
    func push() {
        guard ready, let view else { return }
        view.evaluateJavaScript("window.updateMap && window.updateMap(\(pending))", completionHandler: nil)
        #if os(macOS)
        saveSnapshot(of: view)
        #endif
    }
    #if os(macOS)
    private var lastSnapshot = Date.distantPast
    /// Development aid: with SOUNDBOUND_MAP_SNAPSHOT set, the map saves a picture of itself about once a second,
    /// because a web view's contents do not appear in ordinary window captures.
    private func saveSnapshot(of view: WKWebView) {
        guard ProcessInfo.processInfo.environment["SOUNDBOUND_MAP_SNAPSHOT"] != nil, Date().timeIntervalSince(lastSnapshot) > 1 else { return }
        lastSnapshot = Date()
        view.takeSnapshot(with: nil) { image, _ in
            guard let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("soundbound-audio-map.png"))
        }
    }
    #endif
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "control" {
            guard let body = message.body as? [String: Any], let id = body["id"] as? String else { return }
            onControl(id, (body["value"] as? NSNumber)?.doubleValue ?? 0); return
        }
        ready = true; push()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true; push()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { NSLog("Soundbound audio map: load failed: %@", error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { NSLog("Soundbound audio map: could not start loading: %@", error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { NSLog("Soundbound audio map: web content process ended") }
    // The page is local and self-contained. Nothing in it may navigate anywhere else.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

private enum AudioMapPage {
    static var url: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "map", withExtension: "html", subdirectory: "AudioMap")
        #else
        return Bundle.main.url(forResource: "map", withExtension: "html", subdirectory: "AudioMap")
        #endif
    }
    static func make(_ coordinator: AudioMapCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "ready")
        configuration.userContentController.add(coordinator, name: "control")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        coordinator.view = view
        if let url { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { NSLog("Soundbound audio map: page not found in the app bundle") }
        return view
    }
}

#if os(macOS)
private struct AudioMapWebView: NSViewRepresentable {
    let json: String
    let tick: Int
    let onControl: (String, Double) -> Void
    func makeCoordinator() -> AudioMapCoordinator { AudioMapCoordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let view = AudioMapPage.make(context.coordinator)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.onControl = onControl; context.coordinator.pending = json; context.coordinator.push() }
}
#else
private struct AudioMapWebView: UIViewRepresentable {
    let json: String
    let tick: Int
    let onControl: (String, Double) -> Void
    func makeCoordinator() -> AudioMapCoordinator { AudioMapCoordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let view = AudioMapPage.make(context.coordinator)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.onControl = onControl; context.coordinator.pending = json; context.coordinator.push() }
}
#endif
