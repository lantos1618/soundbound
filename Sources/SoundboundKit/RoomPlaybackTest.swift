import Foundation
import Combine

public enum RoomTestTarget {
    case local(id: String, name: String)
    case remote(peer: String, output: String?, name: String)
    var name: String {
        switch self { case .local(_, let name), .remote(_, _, let name): return name }
    }
}

/// Tests outputs in order. Remote playback still requires receiver approval.
public final class RoomPlaybackTest: ObservableObject {
    @Published public private(set) var active = false
    @Published public private(set) var status = ""
    private var remaining: [RoomTestTarget] = []
    private var observation: AnyCancellable?
    private var generation = UUID()
    private var remoteActive = false
    private weak var store: HubStore?
    private var local: ((String) -> Void)?

    public init() {}
    public func start(_ targets: [RoomTestTarget], store: HubStore, local: @escaping (String) -> Void) {
        guard !active, !store.mesh.active else { return }
        self.store = store; self.local = local; remaining = targets
        guard !targets.isEmpty else { status = "No available speakers in this room."; return }
        generation = UUID(); active = true
        next()
    }
    private func next() {
        observation = nil; remoteActive = false
        guard active, let store else { return }
        guard !remaining.isEmpty else { active = false; status = "Test sequence finished."; return }
        let target = remaining.removeFirst(), token = generation
        status = "Testing \(target.name)…"
        switch target {
        case .local(let id, _):
            local?(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                guard self?.generation == token else { return }; self?.next()
            }
        case .remote(let peer, let output, _):
            guard store.nearby.contains(where: { $0.id == peer }) else { next(); return }
            remoteActive = true
            observation = store.mesh.$active.dropFirst().filter { !$0 }.sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard self?.generation == token else { return }; self?.next()
                }
            }
            store.sendAudioTest(to: peer, outputID: output, repeating: false)
            if !store.mesh.active { next() }
        }
    }
    public func stop() {
        generation = UUID(); observation = nil; remaining = []; active = false; status = "Test stopped."
        if remoteActive { store?.mesh.stop() }; remoteActive = false
    }
}
