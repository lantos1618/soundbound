import XCTest
@testable import SoundboundKit

final class RoomSyncTests: XCTestCase {
    private func pair(_ host: HubStore, with guest: Identity) throws {
        let (_, invite) = try SignedEnvelope.from(link: host.inviteLink)
        let card = PeerCard(publicKey: guest.publicKey, name: "Peer", kind: "mac")
        let join = JoinMessage(requestID: UUID().uuidString, inviteNonce: invite.nonce, peer: card, created: Date())
        host.receive(try guest.sign(join)) { _ in }
        host.decide(try XCTUnwrap(host.requests.first), approve: true)
    }
    private func store(_ identity: Identity) -> HubStore {
        HubStore(identity: identity, defaults: UserDefaults(suiteName: "room-sync-test." + UUID().uuidString)!)
    }
    func testMemberCanRequestOwnOutputButCannotAddUnknownOrUnpairedOutput() throws {
        let ownerID = try Identity(ephemeral: true), guestID = try Identity(ephemeral: true), stranger = try Identity(ephemeral: true)
        let owner = store(ownerID)
        try pair(owner, with: guestID)
        owner.addRoom(name: "Room", region: "Home", policy: .request)
        let room = owner.rooms[0]
        owner.movePeer(guestID.id, to: room.id)
        var output = LocalAudioDevice(id: "speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        output.hasOutput = true
        owner.peerAudioDevices[guestID.id] = [output]
        var request = RoomComponentRequest(sender: guestID.id, recipient: ownerID.id, roomID: room.id, component: "speaker", included: true)
        var reply: SignedEnvelope?
        XCTAssertTrue(owner.receiveRoomComponent(try guestID.sign(request)) { reply = $0 })
        XCTAssertTrue(try XCTUnwrap(reply).verified(as: RoomComponentReply.self).accepted)
        XCTAssertTrue(owner.audioMemberships[HubStore.remoteComponentID(peer: guestID.id, component: "speaker")]?.contains(room.id) == true)
        XCTAssertTrue(owner.receiveRoomComponent(try guestID.sign(request)) { _ in XCTFail("Replayed membership request") })
        request.id = UUID().uuidString
        request.component = "unknown"; reply = nil
        XCTAssertTrue(owner.receiveRoomComponent(try guestID.sign(request)) { reply = $0 })
        XCTAssertFalse(try XCTUnwrap(reply).verified(as: RoomComponentReply.self).accepted)
        request.sender = stranger.id
        XCTAssertTrue(owner.receiveRoomComponent(try stranger.sign(request)) { _ in XCTFail("Unpaired sender") })
    }
    func testOnlyGuestWhoCanControlMayChangeTheOwnersDevices() throws {
        let ownerID = try Identity(ephemeral: true), guestID = try Identity(ephemeral: true)
        let owner = store(ownerID)
        try pair(owner, with: guestID)
        owner.addRoom(name: "Room", region: "Home", policy: .invite)
        let room = owner.rooms[0]
        var speaker = LocalAudioDevice(id: "owner-speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        speaker.hasOutput = true
        owner.reportedAudioDevices = [speaker]
        func ask(included: Bool, component: String = "owner-speaker") throws -> Bool {
            let request = RoomComponentRequest(sender: guestID.id, recipient: ownerID.id, roomID: room.id,
                                               component: component, included: included, host: ownerID.id)
            var reply: SignedEnvelope?
            XCTAssertTrue(owner.receiveRoomComponent(try guestID.sign(request)) { reply = $0 })
            return try XCTUnwrap(reply).verified(as: RoomComponentReply.self).accepted
        }
        // Paired but not invited, then invited to listen: neither may touch the owner's speaker.
        XCTAssertFalse(try ask(included: true))
        owner.setGuest(guestID.id, role: .listen, in: room.id)
        XCTAssertFalse(try ask(included: true))
        XCTAssertNil(owner.audioMemberships["owner-speaker"])
        // Promoted to control: may add and remove it, but not a component the owner cannot see.
        owner.setGuest(guestID.id, role: .control, in: room.id)
        XCTAssertEqual(owner.rooms[0].role(of: guestID.id), .control)
        XCTAssertTrue(try ask(included: true))
        XCTAssertTrue(owner.audioMemberships["owner-speaker"]?.contains(room.id) == true)
        XCTAssertFalse(try ask(included: true, component: "made-up"))
        XCTAssertTrue(try ask(included: false))
        XCTAssertFalse(owner.audioMemberships["owner-speaker"]?.contains(room.id) == true)
        // Removed from the room: control is gone again.
        owner.setGuest(guestID.id, role: nil, in: room.id)
        XCTAssertFalse(try ask(included: true))
    }
    func testOnlyADeviceOnTheSameVerifiedAccountMayEditOrDeleteTheRoom() throws {
        let ownerID = try Identity(ephemeral: true), otherID = try Identity(ephemeral: true)
        let owner = store(ownerID)
        owner.accountID = { "apple-user-1" }
        try pair(owner, with: otherID)
        owner.addRoom(name: "Room", region: "Home", policy: .invite)
        let room = owner.rooms[0]
        func edit(_ change: AudioRoom?) throws -> Bool {
            let request = RoomEditRequest(sender: otherID.id, recipient: ownerID.id, roomID: room.id, room: change)
            var reply: SignedEnvelope?
            XCTAssertTrue(owner.receiveRoomEdit(try otherID.sign(request)) { reply = $0 })
            return try XCTUnwrap(reply).verified(as: RoomComponentReply.self).accepted
        }
        var renamed = room; renamed.name = "Studio"; renamed.owner = otherID.id
        // Paired, but no verified account: refused.
        XCTAssertFalse(try edit(renamed))
        // Verified, but a different Apple Account: refused.
        owner.linkedAccounts[otherID.id] = LinkedAccount(subject: "apple-user-2", proofHash: "x")
        XCTAssertFalse(owner.isOwnDevice(otherID.id))
        XCTAssertFalse(try edit(renamed))
        XCTAssertEqual(owner.rooms[0].name, "Room")
        // Same account: the rename lands, but ownership cannot be taken.
        owner.linkedAccounts[otherID.id] = LinkedAccount(subject: "apple-user-1", proofHash: "y")
        XCTAssertTrue(try edit(renamed))
        XCTAssertEqual(owner.rooms[0].name, "Studio")
        XCTAssertEqual(owner.rooms[0].owner, ownerID.id)
        // Signing out on the owner removes the link.
        owner.accountID = { nil }
        XCTAssertFalse(try edit(nil))
        owner.accountID = { "apple-user-1" }
        XCTAssertTrue(try edit(nil))
        XCTAssertTrue(owner.rooms.isEmpty)
    }
    func testAccountProofMustBeAppleSignedAndBoundToThatDeviceKey() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(try XCTUnwrap(SecKeyCopyPublicKey(privateKey)), nil)) as Data
        // PKCS#1 for a 2048-bit key: 30 82 LL LL 02 82 01 01 00 <256-byte modulus> 02 03 <3-byte exponent>.
        let key = AppleAccountProof.Key(kid: "test", n: der.subdata(in: 9..<265).url64, e: der.suffix(3).url64)
        let device = try Identity(ephemeral: true), other = try Identity(ephemeral: true)
        func token(_ claims: [String: Any], signer: SecKey = privateKey) throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]).url64
            let body = try JSONSerialization.data(withJSONObject: claims).url64
            let signature = try XCTUnwrap(SecKeyCreateSignature(signer, .rsaSignatureMessagePKCS1v15SHA256, Data((header + "." + body).utf8) as CFData, nil)) as Data
            return header + "." + body + "." + signature.url64
        }
        let now = Date()
        var claims: [String: Any] = ["iss": "https://appleid.apple.com", "aud": "app.soundbound.ios", "sub": "apple-user-1",
                                     "iat": Int(now.timeIntervalSince1970) - 60, "nonce": AppleAccountProof.nonce(forDevice: device.publicKey)]
        let good = try token(claims)
        XCTAssertEqual(AppleAccountProof.verifiedSubject(good, devicePublicKey: device.publicKey, keys: [key], now: now), "apple-user-1")
        // The same token offered by a different device proves nothing.
        XCTAssertNil(AppleAccountProof.verifiedSubject(good, devicePublicKey: other.publicKey, keys: [key], now: now))
        // Signed by someone who is not Apple.
        let forger = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        XCTAssertNil(AppleAccountProof.verifiedSubject(try token(claims, signer: forger), devicePublicKey: device.publicKey, keys: [key], now: now))
        // A tampered subject breaks the signature.
        let parts = good.split(separator: ".").map(String.init)
        claims["sub"] = "apple-user-2"
        let swapped = parts[0] + "." + (try JSONSerialization.data(withJSONObject: claims).url64) + "." + parts[2]
        XCTAssertNil(AppleAccountProof.verifiedSubject(swapped, devicePublicKey: device.publicKey, keys: [key], now: now))
        // Issued for another app, or too long ago.
        claims["sub"] = "apple-user-1"; claims["aud"] = "com.example.other"
        XCTAssertNil(AppleAccountProof.verifiedSubject(try token(claims), devicePublicKey: device.publicKey, keys: [key], now: now))
        claims["aud"] = "app.soundbound.mac"; claims["iat"] = Int(now.timeIntervalSince1970) - 181 * 86_400
        XCTAssertNil(AppleAccountProof.verifiedSubject(try token(claims), devicePublicKey: device.publicKey, keys: [key], now: now))
    }
    func testMirrorsOwnerLayoutWithCorrectLocalHostAndComponentIDs() throws {
        let ownerIdentity = try Identity(ephemeral: true), phoneIdentity = try Identity(ephemeral: true)
        let owner = store(ownerIdentity), phone = store(phoneIdentity)
        try pair(owner, with: phoneIdentity); try pair(phone, with: ownerIdentity)
        owner.addRoom(name: "Studio", region: "Home", policy: .request)
        let room = try XCTUnwrap(owner.rooms.first)
        owner.moveDevice(to: room.id)
        owner.movePeer(phoneIdentity.id, to: room.id)
        owner.moveAudioDevice(HubStore.remoteComponentID(peer: phoneIdentity.id, component: "speaker"), to: room.id)
        XCTAssertTrue(phone.mergeRoomLayouts(owner.ownedRoomLayouts(), from: ownerIdentity.id))
        XCTAssertEqual(phone.rooms.first?.name, "Studio")
        XCTAssertTrue(phone.deviceRooms.contains(room.id))
        XCTAssertTrue(phone.peerMemberships[ownerIdentity.id]?.contains(room.id) == true)
        XCTAssertTrue(phone.audioMemberships["speaker"]?.contains(room.id) == true)
        var renamed = room; renamed.name = "Office"
        owner.updateRoom(renamed)
        XCTAssertTrue(phone.mergeRoomLayouts(owner.ownedRoomLayouts(), from: ownerIdentity.id))
        XCTAssertEqual(phone.rooms.first?.name, "Office")
        owner.deleteRoom(room.id)
        XCTAssertTrue(owner.rooms.isEmpty)
        XCTAssertTrue(owner.deviceRooms.isEmpty)
        XCTAssertTrue(phone.mergeRoomLayouts(owner.ownedRoomLayouts(), from: ownerIdentity.id))
        XCTAssertTrue(phone.rooms.isEmpty)
        XCTAssertFalse(phone.deviceRooms.contains(room.id))
    }
    func testUnpairedOrForgedOwnerCannotReplaceRoom() throws {
        let a = try Identity(ephemeral: true), b = try Identity(ephemeral: true)
        let host = store(a)
        host.addRoom(name: "Mine", region: "Home", policy: .request)
        let room = try XCTUnwrap(host.rooms.first)
        XCTAssertFalse(host.mergeRoomLayouts([RoomLayout(room: room, hosts: [], components: [])], from: b.id))
        try pair(host, with: b)
        XCTAssertFalse(host.mergeRoomLayouts([RoomLayout(room: room, hosts: [], components: [])], from: b.id))
        XCTAssertEqual(host.rooms.first?.owner, a.id)
    }
    func testActiveRoomIsExclusiveAndDoesNotChangeMemberships() throws {
        let host = store(try Identity(ephemeral: true))
        host.addRoom(name: "A", region: "Home", policy: .request)
        host.addRoom(name: "B", region: "Home", policy: .request)
        let a = host.rooms[0].id, b = host.rooms[1].id
        host.moveDevice(to: a); host.moveDevice(to: b)
        let memberships = host.deviceRooms
        host.setActiveRoom(a)
        XCTAssertEqual(host.activeRoom?.id, a)
        host.setActiveRoom(b)
        XCTAssertEqual(host.activeRoom?.id, b)
        XCTAssertEqual(host.deviceRooms, memberships)
        host.setActiveRoom("unknown")
        XCTAssertEqual(host.activeRoom?.id, b)
        host.setActiveRoom(nil)
        XCTAssertNil(host.activeRoom)
        XCTAssertEqual(host.deviceRooms, memberships)
    }
    func testMoveRequiresPairedSenderAndExplicitApproval() throws {
        let a = try Identity(ephemeral: true), b = try Identity(ephemeral: true)
        let host = store(a)
        let card = PeerCard(publicKey: b.publicKey, name: "Phone", kind: "iphone")
        let request = DeviceMoveRequest(sender: card, recipient: a.id, deviceName: "Headphones")
        let signed = try b.sign(request)
        host.receive(signed) { _ in XCTFail("Unpaired sender received a reply") }
        XCTAssertNil(host.deviceMoveRequest)
        try pair(host, with: b)
        var didConnect = false
        host.onApprovedDeviceMove = { _ in didConnect = true }
        host.receive(signed) { _ in }
        XCTAssertNotNil(host.deviceMoveRequest)
        XCTAssertFalse(didConnect)
        host.decideDeviceMove(approve: true)
        XCTAssertTrue(didConnect)
        host.receive(signed) { _ in XCTFail("Replay was accepted") }
        XCTAssertNil(host.deviceMoveRequest)
    }

    func testBuiltInCannotRequestHostMove() throws {
        let host = store(try Identity(ephemeral: true))
        var speaker = LocalAudioDevice(id: "speaker", name: "Speaker", icon: "speaker", detail: "", status: "")
        speaker.connection = .builtIn
        host.requestDeviceMove(speaker, to: host.deviceID)
        XCTAssertNil(host.deviceMoveRequest)
        speaker.connection = .bluetooth
        host.requestDeviceMove(speaker, to: host.deviceID)
        XCTAssertNotNil(host.deviceMoveRequest)
    }
}

final class MeterVisualisationTests: XCTestCase {
    func testBandsFindTheToneThatIsPlaying() {
        // A 1 kHz tone should light the band nearest 1 kHz far more than the lowest and highest bands.
        let samples = (0..<512).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 24_000)) * 0.5 }
        let bands = DeviceAudioActivity.bands(samples)
        XCTAssertEqual(bands.count, DeviceAudioActivity.bandCount)
        let loudest = bands.indices.max { bands[$0] < bands[$1] }!
        let frequency = 80 * pow(10_000 / 80, Double(loudest) / Double(DeviceAudioActivity.bandCount - 1))
        XCTAssertEqual(frequency, 1_000, accuracy: 250)
        XCTAssertGreaterThan(bands[loudest], bands[0] * 3)
        XCTAssertGreaterThan(bands[loudest], bands[DeviceAudioActivity.bandCount - 1] * 3)
    }
    func testNewerSharedSettingWinsAndOlderIsIgnored() {
        let activity = DeviceAudioActivity()
        let start = Date()
        activity.setVisualisation(.amplitude, changed: start)
        activity.adopt(SharedSettings(visualisation: "frequency", changed: start.addingTimeInterval(-5)))
        XCTAssertEqual(activity.visualisation, .amplitude)
        activity.adopt(SharedSettings(visualisation: "frequency", changed: start.addingTimeInterval(5)))
        XCTAssertEqual(activity.visualisation, .frequency)
        activity.adopt(SharedSettings(visualisation: "amplitude", changed: start.addingTimeInterval(3_600)))
        XCTAssertEqual(activity.visualisation, .frequency)
        activity.setVisualisation(.amplitude)
    }
}

final class AudioMapMergeTests: XCTestCase {
    func testAPublishedMapSurvivesTheWireWithoutControlsOrDetails() throws {
        var map = AudioMapSnapshot()
        map.nodes = [.init(id: "source", kind: "source", stage: "Source", title: "Mic", subtitle: "", active: true, level: [0.5],
                           metrics: [.init(label: "Kind", value: "Microphone", tone: nil)], total: nil, details: "", column: 0, row: 0)]
        map.regions = [.init(id: "device:self", kind: "device", label: "Laptop · this device", members: ["source"])]
        let decoded = try JSONDecoder().decode(AudioMapSnapshot.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded.nodes.first?.title, "Mic")
        XCTAssertNil(decoded.nodes.first?.controls)
        XCTAssertEqual(decoded.regions.first?.members, ["source"]); XCTAssertEqual(decoded.version, AudioMapSnapshot.currentVersion)
    }
}

extension AudioMapMergeTests {
    private func node(_ id: String, column: Double, row: Double, active: Bool = false) -> AudioMapSnapshot.Node {
        .init(id: id, kind: "stage", stage: "S", title: id, subtitle: "", active: active, level: nil, metrics: [], total: nil, details: "", column: column, row: row)
    }
    /// Two devices that each describe only themselves become one graph: each device once, and one shared
    /// network card that both devices' connections meet at.
    func testDevicesJoinIntoOneGraph() throws {
        func fragment(me: String, other: String) -> AudioMapSnapshot {
            var map = AudioMapSnapshot()
            map.nodes = [node("source", column: 0, row: 0), node("room:r", column: 2, row: 0), node("r|x:encrypt", column: 3, row: 0, active: me == "A"),
                         node("link:" + other, column: 4, row: 0, active: me == "A"), node("net|" + other, column: 7.7, row: 0, active: me == "A"),
                         node("recv|" + other + "|r|spk", column: 5, row: 1), node("hw:spk", column: 6, row: 1)]
            map.edges = [.init(id: "e1", from: "link:" + other, to: "net|" + other, label: nil, active: me == "A", both: true),
                         .init(id: "e2", from: "link:" + other, to: "recv|" + other + "|r|spk", label: nil, active: false)]
            return map
        }
        let joined = HubStore.joinAudioMaps([("A", "A · this device", fragment(me: "A", other: "B"), true),
                                             ("B", "B · yours", fragment(me: "B", other: "A"), false)], roomID: "", meter: "amplitude")
        XCTAssertEqual(joined.nodes.count, 13)
        XCTAssertEqual(joined.regions.filter { $0.kind == "device" }.map(\.label).sorted(), ["A · this device", "B · yours"])
        let network = try XCTUnwrap(joined.regions.first { $0.kind == "network" })
        XCTAssertEqual(network.members, ["dev:A/net|B"])
        XCTAssertEqual(joined.regions.filter { $0.kind == "network" }.count, 1)
        // The network card sits in the gap between the two devices, and the lines to it run down from the upper
        // device and up from the lower one.
        let wire = try XCTUnwrap(joined.nodes.first { $0.id == "dev:A/net|B" })
        XCTAssertGreaterThan(wire.row, joined.nodes.filter { $0.id.hasPrefix("dev:A/") && $0.id != wire.id }.map(\.row).max()!)
        XCTAssertLessThan(wire.row, joined.nodes.filter { $0.id.hasPrefix("dev:B/") }.map(\.row).min()!)
        XCTAssertEqual(joined.edges.first { $0.from == "dev:A/link:B" }?.fromSide, "bottom")
        XCTAssertEqual(joined.edges.first { $0.from == "dev:B/link:A" && $0.to == wire.id }?.fromSide, "top")
        // Both devices' connections end at the one shared card, and it is live because one side is sending.
        let wires = joined.edges.filter { $0.to == "dev:A/net|B" }
        XCTAssertEqual(Set(wires.map(\.from)), ["dev:A/link:B", "dev:B/link:A"])
        XCTAssertTrue(wires.allSatisfy { $0.both == true })
        XCTAssertEqual(joined.nodes.first { $0.id == "dev:A/net|B" }?.active, true)
        // The second device sits below the first, never on top of it.
        let rowsA = joined.nodes.filter { $0.id.hasPrefix("dev:A/") && !$0.id.contains("net|") }.map(\.row), rowsB = joined.nodes.filter { $0.id.hasPrefix("dev:B/") }.map(\.row)
        XCTAssertGreaterThan(rowsB.min()!, rowsA.max()!)
        let data = try JSONEncoder().encode(joined)
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("soundbound-joined-map.json"))
    }
}

extension MeterVisualisationTests {
    /// Tiny packets must not each become a bar: the clock adds one bar per step for whatever arrived, and the
    /// chart keeps moving with empty bars when nothing does.
    func testMeterIsAStripChartDrivenByTheClock() {
        let activity = DeviceAudioActivity()
        var packet = Data()
        for index in 0..<6 { var sample = Int16(8_000 * sin(Double(index))).littleEndian; withUnsafeBytes(of: &sample) { packet.append(contentsOf: $0) } }
        for _ in 0..<160 { activity.updateLevel("x", pcm: packet) }
        XCTAssertNil(activity.waveforms["x"])
        activity.showStreamLevel("x", pcm: packet, recording: false)
        activity.tickMeters()
        XCTAssertEqual(activity.waveforms["x"]?.count, 1)
        XCTAssertGreaterThan(activity.waveforms["x"]?.last ?? 0, 0.1)
        activity.tickMeters()
        XCTAssertEqual(activity.waveforms["x"]?.count, 2)
        XCTAssertEqual(activity.waveforms["x"]?.last, 0)
        XCTAssertGreaterThan(activity.barHeights("x").first ?? 0, 0.3)
    }
}

final class DeviceTuningTests: XCTestCase {
    func testTuningRequestSurvivesTheWire() throws {
        let request = DeviceTuningRequest(sender: "a", recipient: "b", control: "floor", value: 12)
        let decoded = try JSONDecoder().decode(DeviceTuningRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.kind, "device-tuning-request")
        XCTAssertEqual(decoded.control, "floor")
        XCTAssertEqual(decoded.value, 12)
        XCTAssertNil(decoded.accountProof)
    }
}

extension DeviceTuningTests {
    func testDirectionChoicesKeepTheirOrderOnTheWire() {
        // The request carries the choice as its position in this list, so the order must not change.
        XCTAssertEqual(AudioDirection.allCases, [.both, .send, .receive])
    }
}
