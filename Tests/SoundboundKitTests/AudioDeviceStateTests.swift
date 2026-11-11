import XCTest
@testable import SoundboundKit

final class AudioDeviceStateTests: XCTestCase {
    private func device(_ id: String, available: Bool = true) -> LocalAudioDevice {
        var result = LocalAudioDevice(id: id, name: "AirPods", icon: "headphones", detail: "Bluetooth", status: "Available")
        result.isAvailable = available
        return result
    }
    func testDuplicateReportsCollapseAndConnectedReportWins() {
        var connected = device("bluetooth:AA:BB:CC:DD:EE:FF")
        connected.hasOutput = true; connected.selectedOutput = true; connected.volume = 0.6
        let disconnected = device("bluetooth:aa-bb-cc-dd-ee-ff", available: false)
        let result = AudioDeviceInventory.reconcile([disconnected, connected, disconnected])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].selectedOutput)
        XCTAssertEqual(result[0].volume, 0.6)
        XCTAssertEqual(AudioDeviceInventory.reconcile(result), result)
    }
    func testSameNameIsNotProofOfIdentity() {
        XCTAssertEqual(AudioDeviceInventory.reconcile([device("first"), device("second")]).count, 2)
    }
    func testInputAndOutputWithSharedPhysicalIdentityBecomeOneDevice() {
        var input = device("input:port")
        input.physicalID = "ios-port:port"; input.hasInput = true; input.selectedInput = true
        var output = device("port")
        output.physicalID = "ios-port:port"; output.hasOutput = true; output.selectedOutput = true
        let result = AudioDeviceInventory.reconcile([input, output])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, output.id)
        XCTAssertTrue(result[0].hasInput && result[0].hasOutput)
        XCTAssertTrue(result[0].selectedInput && result[0].selectedOutput)
    }
    func testRequestedRouteWaitsForObservationThenConfirms() {
        let now = Date()
        var state = AudioDeviceState()
        var report = device("port")
        state.observe(report, now: now)
        state.request(.useOutput, now: now)
        state.observe(report, now: now.addingTimeInterval(1))
        XCTAssertEqual(state.observed, .available)
        XCTAssertEqual(state.transition, .pending)
        report.selectedOutput = true
        state.observe(report, now: now.addingTimeInterval(2))
        XCTAssertEqual(state.observed, .output)
        XCTAssertEqual(state.transition, .settled)
        XCTAssertEqual(state.intent, .none)
    }
    func testUnsuccessfulRequestTimesOutWithoutChangingObservedState() {
        let now = Date()
        var state = AudioDeviceState()
        state.request(.connect, now: now)
        state.observe(nil, now: now.addingTimeInterval(16))
        XCTAssertEqual(state.observed, .disconnected)
        XCTAssertEqual(state.transition, .failed)
        state.observe(device("port"), now: now.addingTimeInterval(16.5))
        XCTAssertEqual(state.transition, .settled)
        state.request(.connect, now: now.addingTimeInterval(17))
        XCTAssertEqual(state.transition, .pending)
    }
    func testUnsolicitedChangesUpdateFactsWithoutCreatingIntent() {
        var state = AudioDeviceState()
        var report = device("port"); report.selectedOutput = true
        state.observe(report)
        state.observe(nil)
        XCTAssertEqual(state.observed, .disconnected)
        XCTAssertEqual(state.intent, .none)
        XCTAssertEqual(state.transition, .settled)
    }
    func testPeerObservationsAreDeduplicatedAndNotOverwrittenByLocalSnapshot() throws {
        let store = HubStore(identity: try Identity(ephemeral: true), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let peer = "test-peer", id = HubStore.remoteComponentID(peer: peer, component: "port")
        var report = device("port"); report.selectedOutput = true
        store.observePeerAudioDevices([report, report], peerID: peer)
        XCTAssertEqual(store.peerAudioDevices[peer]?.count, 1)
        store.observeAudioDevices([])
        XCTAssertEqual(store.audioDeviceStates[id]?.observed, .output)
        store.observePeerAudioDevices([], peerID: peer)
        XCTAssertEqual(store.audioDeviceStates[id]?.observed, .disconnected)
    }
    func testMoveRequiresMatchingHostIdentityAndSelectedOutput() throws {
        let store = HubStore(identity: try Identity(ephemeral: true), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.outgoingDeviceMove = HeadphoneMoveProgress(id: "request", targetID: "target", deviceIdentity: "headphones", deviceName: "AirPods", targetName: "Phone")
        var wrongDevice = device("other"); wrongDevice.selectedOutput = true
        store.observePeerAudioDevices([wrongDevice], peerID: "target")
        XCTAssertEqual(store.outgoingDeviceMove?.phase, .requesting)
        var correctDevice = device("headphones"); correctDevice.selectedOutput = true
        store.observePeerAudioDevices([correctDevice], peerID: "other-host")
        XCTAssertEqual(store.outgoingDeviceMove?.phase, .requesting)
        store.observePeerAudioDevices([correctDevice], peerID: "target")
        XCTAssertEqual(store.outgoingDeviceMove?.phase, .connected)
    }
}
