import SwiftUI
import SceneKit

struct RoomSpatialLayoutSummary { let placed: Int; let total: Int }

struct RoomSpatialPoint: Codable, Equatable {
    var x: Double = 0
    var y: Double = 1
    var z: Double = 0
    var valid: Bool { x.isFinite && y.isFinite && z.isFinite && abs(x) <= 5 && abs(z) <= 5 && (0...3).contains(y) }
}

/// A manual planning view, kept distinct from measured room/device positions.
struct RoomSpatialView: View {
    @ObservedObject var store: HubStore
    let roomID: String
    let localDevices: [LocalAudioDevice]
    @Environment(\.dismiss) private var dismiss
    @State private var scene = SCNScene()
    @State private var positions: [String: RoomSpatialPoint] = [:]
    @State private var selected = ""
    @State private var scanning = false
    @State private var x = 0.0
    @State private var y = 1.2
    @State private var z = 0.0

    private struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let input: Bool
    }
    private var room: AudioRoom? { store.rooms.first { $0.id == roomID } }
    private var storageKey: String { "room-spatial-layout:" + roomID }
    private var items: [Item] {
        var result: [Item] = []
        // Every speaker and microphone in the room can be placed, not only the speakers.
        for device in localDevices where store.deviceRooms.contains(roomID) || store.audioDevice(device.id, belongsTo: roomID) {
            result.append(Item(id: RoomSpatialStore.deviceKey(host: store.deviceID, device: device.id),
                               name: store.componentTitle(device.name, on: store.name, titled: store.ownDeviceTitle), input: device.hasInput && !device.hasOutput))
        }
        for peer in store.friends {
            let all = store.peerMemberships[peer.id]?.contains(roomID) == true
            let components = (store.peerAudioDevices[peer.id] ?? []).filter {
                all || store.audioMemberships[HubStore.remoteComponentID(peer: peer.id, component: $0.id)]?.contains(roomID) == true
            }
            for device in components {
                result.append(Item(id: RoomSpatialStore.deviceKey(host: peer.id, device: device.id),
                                   name: store.componentTitle(device.name, on: peer.card.name, titled: store.deviceTitle(peer)), input: device.hasInput && !device.hasOutput))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }
    private var draft: RoomSpatialPoint { RoomSpatialPoint(x: x, y: y, z: z) }

    private var layout: RoomSpatialLayoutSummary {
        let placed = items.filter { positions[$0.id] != nil }.count
        return RoomSpatialLayoutSummary(placed: placed, total: items.count)
    }
    /// Every hand edit is saved at once; there is no separate save step.
    private func commit() {
        guard !selected.isEmpty else { return }
        positions[selected] = draft
        persist(); updateMarkers()
    }
    private func snapped(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    private var deviceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    let placed = positions[item.id] != nil
                    let current = item.id == selected
                    Button { selected = item.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(current ? Color.orange : placed ? Color.blue : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(item.name).lineLimit(1)
                            if !placed { Text("not placed").foregroundStyle(.secondary) }
                        }
                        .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(current ? Color.orange.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(current ? Color.orange : .clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.name + (placed ? ", placed" : ", not placed"))
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
            }.padding(.vertical, 1)
        }
    }
    private var floorPad: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05))
                Path { path in
                    for index in 1..<10 {
                        let offset = side * CGFloat(index) / 10
                        path.move(to: CGPoint(x: offset, y: 0)); path.addLine(to: CGPoint(x: offset, y: side))
                        path.move(to: CGPoint(x: 0, y: offset)); path.addLine(to: CGPoint(x: side, y: offset))
                    }
                }.stroke(Color.primary.opacity(index10Opacity), lineWidth: 1)
                ForEach(items) { item in
                    if let saved = positions[item.id] {
                        let point = item.id == selected ? draft : saved
                        Circle().fill(item.id == selected ? Color.orange : Color.blue)
                            .frame(width: item.id == selected ? 16 : 10, height: item.id == selected ? 16 : 10)
                            .position(x: (point.x + 5) / 10 * side, y: (point.z + 5) / 10 * side)
                    }
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !selected.isEmpty else { return }
                x = snapped(min(max(Double(value.location.x / side), 0), 1) * 10 - 5)
                z = snapped(min(max(Double(value.location.y / side), 0), 1) * 10 - 5)
                commit()
            })
        }
        .frame(width: padSide, height: padSide)
        .accessibilityElement()
        .accessibilityLabel("Floor plan, seen from above. Drag to place the selected speaker, or use Exact position.")
        .help("Seen from above, 10 × 10 m. Click or drag to place the selected speaker.")
    }
    private let index10Opacity = 0.08
    private var padSide: CGFloat {
        #if os(macOS)
        190
        #else
        150
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(room?.name ?? "Room").font(.title2.weight(.semibold))
                    Text(items.isEmpty ? "Where your speakers are" : "\(layout.placed) of \(layout.total) speakers placed")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                .frame(minHeight: 220, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .bottomLeading) {
                    Text(store.spatial.layouts[roomID].map { $0.usesLiDAR ? "Scanned with LiDAR · drag to look around" : "Scanned with camera · drag to look around" } ?? "No scan yet · 10 × 10 m grid")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule()).padding(10)
                }
                .accessibilityLabel("3D room view. Drag to orbit. Use the floor plan to place a speaker.")
            if items.isEmpty {
                Text("Add a speaker or headphones to this room, then place them here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                deviceChips
                HStack(alignment: .top, spacing: 18) {
                    floorPad
                    VStack(alignment: .leading, spacing: 12) {
                        Text(items.first { $0.id == selected }?.name ?? "").font(.headline).lineLimit(1)
                        Text(positions[selected] == nil ? "Click the floor plan to place it." : String(format: "%.1f m across · %.1f m deep · %.1f m high", x, z, y))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        coordinate("Height", value: Binding(get: { y }, set: { y = $0; commit() }), range: 0...3)
                        DisclosureGroup("Exact position") {
                            VStack(spacing: 8) {
                                coordinate("Left / right", value: Binding(get: { x }, set: { x = $0; commit() }), range: -5...5)
                                coordinate("Front / back", value: Binding(get: { z }, set: { z = $0; commit() }), range: -5...5)
                            }.padding(.top, 6)
                        }.font(.caption)
                        Button("Remove from layout") {
                            positions[selected] = nil; persist(); loadSelection()
                        }.controlSize(.small).disabled(positions[selected] == nil)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                #if os(iOS)
                Button { scanning = true } label: { Label("Scan this room", systemImage: "camera.viewfinder") }
                    .buttonStyle(.borderedProminent)
                #else
                Label("Scan the real room from this room’s menu on your iPhone.", systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                Spacer(minLength: 8)
                Text("A map for now. It does not change the mix yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Hand edits stay on this device. Saved scans are shared with paired room members. Positions are not continuously tracked or acoustically calibrated.")
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 720, height: 740)
        #endif
        .onAppear {
            if let data = UserDefaults.standard.data(forKey: storageKey),
               let saved = try? JSONDecoder().decode([String: RoomSpatialPoint].self, from: data) {
                positions = saved.filter { $0.value.valid }
            }
            if let layout = store.spatial.layouts[roomID] { positions = layout.positions }
            selected = items.first?.id ?? ""
            buildRoom(); loadSelection()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $scanning) {
            RoomLiDARScanView(roomID: roomID, sourceID: store.deviceID,
                targets: items.map { RoomScanTarget(id: $0.id, name: $0.name) },
                phoneKey: localDevices.first(where: { device in device.hasOutput && items.contains(where: { $0.id == RoomSpatialStore.deviceKey(host: store.deviceID, device: device.id) }) }).map { RoomSpatialStore.deviceKey(host: store.deviceID, device: $0.id) },
                existing: store.spatial.layouts[roomID]) { layout in
                    store.spatial.save(layout)
                    positions = layout.positions; buildRoom(); loadSelection()
                }
        }
        #endif
        .onChange(of: store.spatial.layouts[roomID]) { layout in
            if let layout { positions = layout.positions; buildRoom(); loadSelection() }
        }
        .onChange(of: selected) { _ in loadSelection() }
        .onChange(of: items) { newItems in
            if !newItems.contains(where: { $0.id == selected }) { selected = newItems.first?.id ?? "" }
            updateMarkers()
        }
        .onChange(of: draft) { _ in updateMarkers() }
    }

    private func coordinate(_ name: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(name).font(.caption).frame(width: 95, alignment: .leading)
            Slider(value: value, in: range, step: 0.1).accessibilityLabel(name + " position in metres")
            Text(String(format: "%.1f m", value.wrappedValue)).font(.caption).monospacedDigit().frame(width: 55, alignment: .trailing)
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(positions) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
    private func loadSelection() {
        let point = positions[selected] ?? RoomSpatialPoint(x: 0, y: 1, z: 0)
        x = point.x; y = point.y; z = point.z
        updateMarkers()
    }
    private func buildRoom() {
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        #if os(macOS)
        scene.background.contents = NSColor.windowBackgroundColor
        #else
        scene.background.contents = UIColor.systemBackground
        #endif
        for index in -5...5 {
            for axis in 0..<2 {
                let line = SCNBox(width: axis == 0 ? 10 : 0.02, height: 0.008, length: axis == 0 ? 0.02 : 10, chamferRadius: 0)
                line.firstMaterial?.diffuse.contents = color(.secondary.opacity(0.22))
                let node = SCNNode(geometry: line)
                node.position = SCNVector3(axis == 0 ? 0 : Float(index), 0, axis == 0 ? Float(index) : 0)
                scene.rootNode.addChildNode(node)
            }
        }
        for surface in store.spatial.layouts[roomID]?.surfaces ?? [] {
            let plane = SCNPlane(width: CGFloat(surface.width), height: CGFloat(surface.length))
            // The plane's normal is the node's local Y axis: mostly upright means floor, table or ceiling.
            let level = abs(surface.transform[5]) > 0.7
            plane.firstMaterial?.diffuse.contents = color(level ? .teal.opacity(0.28) : .primary.opacity(0.10))
            plane.firstMaterial?.isDoubleSided = true
            let child = SCNNode(geometry: plane); child.eulerAngles.x = -.pi / 2
            let node = SCNNode(); let t = surface.transform
            node.simdTransform = simd_float4x4(columns: (
                SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
            node.addChildNode(child); scene.rootNode.addChildNode(node)
        }
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 45
        let surfaces = store.spatial.layouts[roomID]?.surfaces ?? []
        let count = Float(max(surfaces.count, 1))
        let centreX = min(max(surfaces.reduce(Float(0)) { $0 + $1.transform[12] } / count, -5), 5)
        let centreZ = min(max(surfaces.reduce(Float(0)) { $0 + $1.transform[14] } / count, -5), 5)
        let reach: Float = surfaces.isEmpty ? 1 : 0.7
        camera.position = SCNVector3(centreX + 7 * reach, 6 * reach, centreZ + 8 * reach)
        camera.look(at: SCNVector3(centreX, 0.3, centreZ))
        scene.rootNode.addChildNode(camera)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .ambient; light.light?.intensity = 600
        scene.rootNode.addChildNode(light)
        updateMarkers()
    }
    private func updateMarkers() {
        scene.rootNode.childNodes.filter { $0.name == "marker" }.forEach { $0.removeFromParentNode() }
        for item in items {
            guard let saved = positions[item.id] else { continue }
            let point = item.id == selected ? draft : saved
            let tint: Color = item.id == selected ? .orange : positions[item.id] == nil ? .gray : item.input ? .green : .blue
            let geometry: SCNGeometry = item.input ? SCNCylinder(radius: 0.08, height: 0.3) : SCNSphere(radius: 0.14)
            geometry.firstMaterial?.diffuse.contents = color(tint)
            let marker = SCNNode(geometry: geometry); marker.name = "marker"
            marker.position = SCNVector3(Float(point.x), Float(point.y), Float(point.z))
            let text = SCNText(string: String(item.name.prefix(40)), extrusionDepth: 0)
            #if os(macOS)
            text.font = NSFont.systemFont(ofSize: 0.22)
            #else
            text.font = UIFont.systemFont(ofSize: 0.22)
            #endif
            text.flatness = 0.1; text.firstMaterial?.diffuse.contents = color(.primary)
            let label = SCNNode(geometry: text)
            label.pivot = SCNMatrix4MakeTranslation((text.boundingBox.min.x + text.boundingBox.max.x) / 2, text.boundingBox.min.y, 0)
            label.position = SCNVector3(0, 0.25, 0)
            label.constraints = [SCNBillboardConstraint()]
            marker.addChildNode(label); scene.rootNode.addChildNode(marker)
        }
    }
    private func color(_ value: Color) -> Any {
        #if os(macOS)
        return NSColor(value)
        #else
        return UIColor(value)
        #endif
    }
}
