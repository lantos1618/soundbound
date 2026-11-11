import Foundation

/// A selected output and an open Bluetooth link are not proof of audible ownership.
/// Confirmation records a completed, user-verified sound test, never a selection.
struct ConnectionCheck: Equatable {
    enum Phase: Equatable { case unverified, testing, awaitingAnswer, confirmed }
    private(set) var phase: Phase = .unverified
    private(set) var testedUID: String?

    mutating func reset() { phase = .unverified; testedUID = nil }
    mutating func begin(uid: String) { phase = .testing; testedUID = uid }
    mutating func finished() { if phase == .testing { phase = .awaitingAnswer } }
    mutating func answer(heard: Bool, currentUID: String?) {
        guard phase == .awaitingAnswer, heard, let testedUID, currentUID == testedUID else { reset(); return }
        phase = .confirmed
    }
    mutating func observe(currentUID: String?, connected: Bool) {
        guard phase != .unverified else { return }
        if !connected || currentUID != testedUID { reset() }
    }
}
