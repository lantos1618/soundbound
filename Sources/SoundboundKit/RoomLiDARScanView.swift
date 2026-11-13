#if os(iOS)
import SwiftUI
import ARKit
import AVFoundation
import CryptoKit

struct RoomScanTarget: Identifiable {
    var id: String
    var name: String
}

struct RoomLiDARScanView: View {
    @StateObject private var model: RoomScanModel
    @Environment(\.dismiss) private var dismiss
    let onSave: (RoomSpatialLayout) -> Void

    init(roomID: String, sourceID: String, targets: [RoomScanTarget], phoneKey: String?,
         existing: RoomSpatialLayout?, onSave: @escaping (RoomSpatialLayout) -> Void) {
        _model = StateObject(wrappedValue: RoomScanModel(roomID: roomID, sourceID: sourceID,
            targets: targets, phoneKey: phoneKey, existing: existing))
        self.onSave = onSave
    }
    var body: some View {
        ZStack(alignment: .top) {
            RoomARCamera(model: model).ignoresSafeArea()
            GeometryReader { proxy in
                ForEach(model.detections) { detection in
                    let rect = model.screenRect(detection.rect, size: proxy.size)
                    Button { model.placeDetection(detection, size: proxy.size) } label: {
                        RoundedRectangle(cornerRadius: 12).stroke(.yellow, lineWidth: 3)
                            .overlay(alignment: .topLeading) {
                                Text(detection.label).font(.caption.bold()).padding(6).background(.yellow, in: Capsule()).foregroundStyle(.black)
                            }
                    }.frame(width: max(1, rect.width), height: max(1, rect.height)).position(x: rect.midX, y: rect.midY)
                    .disabled(!model.hasOrigin || !model.tracking)
                }
            }.ignoresSafeArea()
            VStack {
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Text(model.usesLiDAR ? "LiDAR room scan" : "Camera room scan").font(.headline)
                    Spacer()
                    Text("\(model.placedCount)/\(model.targets.count)")
                }.padding().background(.regularMaterial)
                Spacer()
                Image(systemName: "plus").font(.title).foregroundStyle(.white).shadow(radius: 2).allowsHitTesting(false)
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.hasOrigin ? "2 · Point the + at a device, then tap its name" : "1 · Set the floor").font(.headline)
                Text(model.status).font(.subheadline)
                if model.hasOrigin {
                    // Tapping a device's button puts that device where the + is pointing. Tap it again to move it.
                    ChipFlow(spacing: 8) {
                        ForEach(model.targets) { target in
                            Button { model.selected = target.id; model.placeSelected() } label: {
                                Label(target.name, systemImage: model.isPlaced(target.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.subheadline.weight(.medium)).lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .foregroundStyle(model.isPlaced(target.id) ? Color.white : Color.primary)
                                    .background(model.isPlaced(target.id) ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
                            }.buttonStyle(.plain).disabled(!model.tracking)
                        }
                    }
                    Button("Save room") { model.save { onSave($0); dismiss() } }
                        .buttonStyle(.borderedProminent).disabled(!model.canSave)
                    Text("Aim the + at the device itself, wherever it is, then tap its name below. Tap the name again to move it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Move slowly to scan the floor and table, then aim the crosshair at the floor.").font(.subheadline)
                    Button("Set floor here") { model.setOrigin() }.buttonStyle(.borderedProminent).disabled(!model.tracking)
                }
                Text("Camera processing stays on this phone. Only saved positions and surfaces sync to paired room members.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
        }
        .onDisappear { model.stop() }
    }
}

/// Lays buttons out left to right and wraps onto as many lines as they need.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], height: CGFloat)] {
        var rows: [(indices: [Int], height: CGFloat)] = [], current: [Int] = [], x: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > width { rows.append((current, height)); current = []; x = 0; height = 0 }
            current.append(index); x += size.width + spacing; height = max(height, size.height)
        }
        if !current.isEmpty { rows.append((current, height)) }
        return rows
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let laid = rows(subviews, width: width)
        return CGSize(width: width, height: laid.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, laid.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}

private struct RoomARCamera: UIViewRepresentable {
    let model: RoomScanModel
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        view.delegate = model
        view.session.delegate = model
        view.session.delegateQueue = .main
        model.view = view
        model.start()
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) { view.session.pause() }
}

private final class RoomScanModel: NSObject, ObservableObject, ARSessionDelegate, ARSCNViewDelegate {
    let roomID: String
    let sourceID: String
    let targets: [RoomScanTarget]
    let phoneKey: String?
    let usesLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    let existing: RoomSpatialLayout?
    weak var view: ARSCNView?
    @Published var selected: String
    @Published var status = "Preparing camera…"
    @Published var tracking = false
    @Published var hasOrigin = false
    @Published var canSave = false
    @Published var detections: [RoomObjectDetection] = []
    @Published var detectorAvailable = false
    @Published var placedCount = 0
    private let detector = RoomObjectDetector()
    private var origin: SIMD3<Float>?
    private var positions: [String: RoomSpatialPoint] = [:]
    private var lastUpdate = 0.0
    private var saving = false
    private var stopped = false

    init(roomID: String, sourceID: String, targets: [RoomScanTarget], phoneKey: String?, existing: RoomSpatialLayout?) {
        self.roomID = roomID; self.sourceID = sourceID; self.targets = targets
        self.phoneKey = phoneKey; self.existing = existing; selected = targets.first(where: { $0.id != phoneKey })?.id ?? targets.first?.id ?? ""
    }
    private var mapURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SoundboundSpatialMaps")
        let name = SHA256.hash(data: Data(roomID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".armap")
    }
    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { status = "AR world tracking is unavailable on this device."; return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in DispatchQueue.main.async {
            guard let self, !self.stopped else { return }
            guard allowed else { self.status = "Allow camera access in iPhone Settings to scan this room."; return }
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = [.horizontal, .vertical]
            if self.usesLiDAR { configuration.sceneReconstruction = .mesh }
            if let saved = self.existing, saved.sourceDeviceID == self.sourceID,
               let data = try? Data(contentsOf: self.mapURL), data.count < 30_000_000,
               let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                configuration.initialWorldMap = map
                self.origin = SIMD3(saved.floorOrigin[0], saved.floorOrigin[1], saved.floorOrigin[2])
                self.positions = saved.positions.filter { key, _ in self.targets.contains { $0.id == key } }; self.placedCount = self.positions.count; self.hasOrigin = true
                self.status = "Look around the saved room to restore tracking."
            } else { self.status = "Move the iPhone slowly to scan the floor and table." }
            self.view?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } }
    }
    func stop() { stopped = true; view?.session.pause() }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastUpdate >= 0.25 else { return }
        lastUpdate = frame.timestamp
        detector.detect(frame.capturedImage) { [weak self] detections, available in
            guard let self, !self.stopped else { return }
            self.detections = detections; self.detectorAvailable = available
        }
        if case .normal = frame.camera.trackingState {
            if !tracking { showMarkers() }; tracking = true
        } else { tracking = false }
        let mapped = frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending
        canSave = tracking && mapped && hasOrigin && !positions.isEmpty && !saving
        if !tracking { status = "Tracking is limited. Move slowly and keep the room in view." }
        else if !hasOrigin { status = "Tracking ready. Aim at the floor and set the origin." }
        else if !mapped { status = "Keep scanning the room before saving the tracking map." }
        else { status = "Tracking ready · \(positions.count) position(s) placed" }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.tracking = false; self?.canSave = false; self?.status = "Scan stopped: " + error.localizedDescription }
    }
    private func hit(alignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
        guard let view else { return nil }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            if let query = view.raycastQuery(from: center, allowing: target, alignment: alignment),
               let hit = view.session.raycast(query).first {
                let p = hit.worldTransform.columns.3
                return SIMD3(p.x, p.y, p.z)
            }
        }
        return nil
    }
    func setOrigin() {
        guard tracking, let point = hit(alignment: .horizontal) else { status = "No horizontal floor surface found under the crosshair."; return }
        origin = point; positions = [:]; placedCount = 0; hasOrigin = true; showMarkers()
        status = "Floor set. Point the + at a device and tap its name."
    }
    func screenRect(_ rect: CGRect, size: CGSize) -> CGRect {
        guard let frame = view?.session.currentFrame else { return .zero }
        let orientation = view?.window?.windowScene?.interfaceOrientation ?? .portrait
        let transform = frame.displayTransform(for: orientation, viewportSize: size)
        let normalized = rect.applying(transform)
        return CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                      width: normalized.width * size.width, height: normalized.height * size.height)
    }
    func placeDetection(_ detection: RoomObjectDetection, size: CGSize) {
        guard let view, hasOrigin, tracking else { return }
        let rect = screenRect(detection.rect, size: size)
        guard let query = view.raycastQuery(from: CGPoint(x: rect.midX, y: rect.midY), allowing: .estimatedPlane, alignment: .any),
              let hit = view.session.raycast(query).first else { status = "Keep scanning the surface around this object."; return }
        let p = hit.worldTransform.columns.3
        place(selected, world: SIMD3(p.x, p.y, p.z))
    }
    func placeSelected() {
        guard tracking, let point = hit(alignment: .any) else { status = "No surface found. Aim at the device or the table directly beneath it."; return }
        place(selected, world: point)
    }
    func isPlaced(_ key: String) -> Bool { positions[key] != nil }
    /// Place the chosen device where the + points, then move on to the next one that has no place yet.
    func placeSelectedAndAdvance() {
        let before = positions[selected]
        placeSelected()
        guard positions[selected] != before, let next = targets.first(where: { positions[$0.id] == nil }) else { return }
        selected = next.id
    }
    func placePhone() {
        guard tracking, let phoneKey, let frame = view?.session.currentFrame else { return }
        let p = frame.camera.transform.columns.3
        place(phoneKey, world: SIMD3(p.x, p.y, p.z))
    }
    private func place(_ key: String, world: SIMD3<Float>) {
        guard let origin else { return }
        let p = world - origin
        let point = RoomSpatialPoint(x: Double(p.x), y: Double(p.y), z: Double(p.z))
        guard point.valid else { status = "Place within 5 m of the origin and between floor level and 3 m high."; return }
        guard targets.contains(where: { $0.id == key }) else { return }
        positions[key] = point; placedCount = positions.count
        status = "Placed " + (targets.first { $0.id == key }?.name ?? "device")
        showMarkers()
    }
    private func showMarkers() {
        guard let view, let origin else { return }
        view.scene.rootNode.childNodes.filter { $0.name == "placed-device" }.forEach { $0.removeFromParentNode() }
        for (key, p) in positions {
            let sphere = SCNSphere(radius: 0.035); sphere.firstMaterial?.diffuse.contents = UIColor.systemOrange
            let node = SCNNode(geometry: sphere); node.name = "placed-device"
            node.simdPosition = origin + SIMD3(Float(p.x), Float(p.y), Float(p.z))
            let text = SCNText(string: targets.first { $0.id == key }?.name ?? key, extrusionDepth: 0)
            text.font = UIFont.systemFont(ofSize: 0.045); text.firstMaterial?.diffuse.contents = UIColor.white
            let label = SCNNode(geometry: text); label.position.y = 0.06
            label.pivot = SCNMatrix4MakeTranslation((text.boundingBox.min.x + text.boundingBox.max.x) / 2, 0, 0)
            label.constraints = [SCNBillboardConstraint()]; node.addChildNode(label)
            view.scene.rootNode.addChildNode(node)
        }
    }
    func save(_ completion: @escaping (RoomSpatialLayout) -> Void) {
        guard canSave, let origin, let frame = view?.session.currentFrame else { return }
        let surfaces = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.prefix(16).compactMap { plane -> RoomSpatialSurface? in
            var t = plane.transform
            t.columns.3 += t.columns.0 * plane.center.x + t.columns.1 * plane.center.y + t.columns.2 * plane.center.z
            t.columns.3.x -= origin.x; t.columns.3.y -= origin.y; t.columns.3.z -= origin.z
            let values = (0..<4).flatMap { column in (0..<4).map { row in t[column][row] } }
            let surface = RoomSpatialSurface(transform: values, width: plane.extent.x, length: plane.extent.z)
            return surface.valid ? surface : nil
        }
        let labels = Dictionary(uniqueKeysWithValues: targets.filter { positions[$0.id] != nil }.map { ($0.id, $0.name) })
        let layout = RoomSpatialLayout(roomID: roomID, sourceDeviceID: sourceID, usesLiDAR: usesLiDAR,
            floorOrigin: [origin.x, origin.y, origin.z], positions: positions, labels: labels, surfaces: surfaces)
        guard layout.valid else { status = "The scan contains an invalid position. Re-place the device."; return }
        saving = true; canSave = false; status = "Saving room tracking map…"
        view?.session.getCurrentWorldMap { [weak self] map, error in DispatchQueue.main.async {
            guard let self, !self.stopped else { return }
            self.saving = false
            guard let map, error == nil else { self.status = "Map not ready. Scan more of the room and try again."; return }
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                guard data.count < 30_000_000 else { self.status = "Tracking map is too large. Start a smaller scan."; return }
                try FileManager.default.createDirectory(at: self.mapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: self.mapURL, options: .atomic)
                completion(layout)
            } catch { self.status = "Could not save the tracking map: " + error.localizedDescription }
        } }
    }
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let plane = anchor as? ARPlaneAnchor else { return nil }
        let geometry = SCNPlane(width: CGFloat(plane.extent.x), height: CGFloat(plane.extent.z))
        geometry.firstMaterial?.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.15)
        geometry.firstMaterial?.isDoubleSided = true
        let surface = SCNNode(geometry: geometry); surface.eulerAngles.x = -.pi / 2
        surface.simdPosition = plane.center
        let root = SCNNode(); root.addChildNode(surface); return root
    }
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let plane = anchor as? ARPlaneAnchor, let surface = node.childNodes.first, let geometry = surface.geometry as? SCNPlane else { return }
        geometry.width = CGFloat(plane.extent.x); geometry.height = CGFloat(plane.extent.z); surface.simdPosition = plane.center
    }
}
#endif
