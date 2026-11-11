import AppKit
import CoreAudio
import IOBluetooth
import AVFAudio
import SoundboundKit

struct Output: Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let bluetooth: Bool
}

enum Audio {
    static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) == noErr
        }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var value: CFString = "" as CFString
        return read(id, selector, into: &value) ? value as String : ""
    }

    static var current: AudioDeviceID {
        var value = AudioDeviceID(0)
        _ = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &value)
        return value
    }

    static var currentInput: AudioDeviceID {
        var value = AudioDeviceID(0)
        _ = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &value)
        return value
    }

    static func outputs() -> [Output] { devices(scope: kAudioDevicePropertyScopeOutput) }
    static func inputs() -> [Output] { devices(scope: kAudioDevicePropertyScopeInput) }
    private static func devices(scope: AudioObjectPropertyScope) -> [Output] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            var transport: UInt32 = 0
            _ = read(id, kAudioDevicePropertyTransportType, into: &transport)
            return Output(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName), bluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func select(_ output: Output) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = output.id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout.size(ofValue: id)), &id)
    }
}

final class SoundModel: NSObject, ObservableObject {
    @Published var outputs: [Output] = []
    @Published var inputs: [Output] = []
    @Published var currentInputID: AudioDeviceID = 0
    @Published var currentID: AudioDeviceID = 0
    @Published var paired: [IOBluetoothDevice] = []
    @Published var message: String?
    @Published var connecting = false
    @Published var releasing = false
    @Published private(set) var connectionCheck = ConnectionCheck()
    @Published private var watchedUID = UserDefaults.standard.string(forKey: "watchedUID")
    @Published private var watchedName = UserDefaults.standard.string(forKey: "watchedName") ?? "Your AirPods"
    @Published private var watchedAddress = UserDefaults.standard.string(forKey: "watchedAddress")
    @Published var quietPrompts: Bool = UserDefaults.standard.object(forKey: "quietPrompts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(quietPrompts, forKey: "quietPrompts") }
    }
    var onDeparture: ((String) -> Void)?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var previouslyOnMac: Bool?
    private var pendingDevice: IOBluetoothDevice?
    private var attemptTimer: Timer?
    private var connectionObserver: IOBluetoothUserNotification?
    private var disconnectObserver: IOBluetoothUserNotification?
    private var verificationEngine: AVAudioEngine?
    private var verificationPlayer: AVAudioPlayerNode?
    private var statusTimer: Timer?
    @Published private var pairedLookupInProgress = false
    @Published var operationID: String?
    private var routingTask: Task<Void, Never>?
    private var connectionLookup: UUID?
    private let routing = VerifiedAudioRouting(backend: CoreAudioRoutingBackend())

    private func rowID(for device: Output) -> String {
        if device.bluetooth {
            if let address = paired.first(where: { matches(device, $0) })?.addressString {
                return "bluetooth:" + address.lowercased()
            }
            if let address = watchedAddress, device.uid == watchedUID || device.name == watchedName {
                return "bluetooth:" + address.lowercased()
            }
        }
        return device.uid
    }

    var localAudioDevices: [LocalAudioDevice] {
        var seen = Set<String>()
        let devices = (outputs + inputs).filter { seen.insert(rowID(for: $0)).inserted }
        var rows = devices.map { device in
            let id = rowID(for: device)
            let output = outputs.first { rowID(for: $0) == id }
            let input = inputs.first { rowID(for: $0) == id }
            let selectedInput = input?.id == currentInputID
            let selectedOutput = output?.id == currentID
            let role = input != nil && output != nil ? "Input & output" : (input != nil ? "Microphone input" : "Audio output")
            let status = selectedInput && selectedOutput ? "Mac input & output" :
                (selectedOutput ? "Mac output" : (selectedInput ? "Mac input" : "Available"))
            var row = LocalAudioDevice(id: id, name: device.name,
                icon: device.bluetooth ? "headphones" : (output != nil ? "speaker.wave.2" : "mic"),
                detail: "This Mac · " + role,
                status: operationID == id ? "Applying…" : (output?.uid == targetOutput?.uid && output != nil && hasVerifiedSound ? "Sound confirmed" : status))
            row.hasInput = input != nil; row.hasOutput = output != nil
            row.selectedInput = selectedInput; row.selectedOutput = selectedOutput
            row.canDisconnect = device.bluetooth && paired.contains { matches(device, $0) }
            row.canTest = device.bluetooth && selectedOutput
            row.awaitingTestAnswer = output?.uid == targetOutput?.uid && output != nil && connectionCheck.phase == .awaitingAnswer
            row.volume = output.flatMap { CoreAudioRoutingBackend().volume($0.id) }
            row.busy = busy
            return row
        }
        for device in paired where !(outputs + inputs).contains(where: { matches($0, device) }) {
            var row = LocalAudioDevice(id: "bluetooth:" + (device.addressString ?? device.name ?? "unknown").lowercased(),
                name: device.name ?? "Bluetooth audio device", icon: "headphones",
                detail: "Paired with this Mac", status: connecting && isTracked(device) ? "Connecting…" : (device.isConnected() ? "Bluetooth connected" : "Not connected"))
            row.isAvailable = device.isConnected()
            row.canConnect = true; row.canDisconnect = device.isConnected(); row.busy = busy
            rows.append(row)
        }
        if hasHeadphones, !rows.contains(where: { $0.name == watchedName }) {
            var row = LocalAudioDevice(id: watchedAddress.map { "bluetooth:" + $0.lowercased() } ?? ("remembered:" + (watchedUID ?? watchedName)),
                name: watchedName, icon: "headphones", detail: "Saved headphones",
                status: connecting ? "Connecting…" : (pairedLookupInProgress ? "Checking Bluetooth…" : "Not available to this Mac"))
            row.isAvailable = false; row.isChecking = pairedLookupInProgress
            row.canConnect = watchedAddress != nil; row.busy = busy
            rows.append(row)
        }
        return rows
    }

    var headphoneName: String { watchedName }
    var busy: Bool { connecting || releasing || operationID != nil || connectionCheck.phase == .testing }
    var hasVerifiedSound: Bool { connectionCheck.phase == .confirmed }
    var hasHeadphones: Bool { watchedUID != nil || watchedAddress != nil }
    var targetOutput: Output? {
        outputs.first { $0.uid == watchedUID } ?? outputs.first { output in
            guard let device = targetDevice else { return false }
            return matches(output, device)
        }
    }
    var targetDevice: IOBluetoothDevice? {
        if let watchedAddress,
           let device = paired.first(where: { $0.addressString == watchedAddress }) { return device }
        if let output = outputs.first(where: { $0.uid == watchedUID }),
           let device = paired.first(where: { matches(output, $0) }) { return device }
        let named = paired.filter { $0.name == watchedName }
        return named.count == 1 ? named.first : nil
    }
    var isOnMac: Bool { targetDevice?.isConnected() == true || targetOutput != nil }
    var isMacAudioSelected: Bool { targetOutput?.id == currentID }
    var ownershipDescription: String {
        if releasing { return "Releasing from this Mac…" }
        if connecting { return "Connecting to this Mac…" }
        if !hasHeadphones { return "Choose your headphones in Setup" }
        if hasVerifiedSound { return "Sound test confirmed by you" }
        if connectionCheck.phase == .testing { return "Playing a short test sound…" }
        if connectionCheck.phase == .awaitingAnswer { return "Did you hear the sound in your AirPods?" }
        if isMacAudioSelected { return "Mac output selected · takeover unconfirmed" }
        if isOnMac { return "Bluetooth connected · takeover unconfirmed" }
        return "Not connected to this Mac"
    }

    override init() {
        super.init()
        refresh()
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit {
        for (var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        attemptTimer?.invalidate()
        connectionObserver?.unregister()
        disconnectObserver?.unregister()
        statusTimer?.invalidate()
    }

    @objc private func bluetoothChanged(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.resetSoundCheck()
            self?.refresh()
            self?.observeTargetDisconnect()
        }
    }

    private func observeTargetDisconnect() {
        disconnectObserver?.unregister()
        disconnectObserver = targetDevice?.register(forDisconnectNotification: self, selector: #selector(bluetoothChanged(_:device:)))
    }

    func refresh() {
        outputs = Audio.outputs()
        inputs = Audio.inputs()
        currentInputID = Audio.currentInput
        currentID = Audio.current
        refreshPairedDevices()
        if !hasHeadphones {
            if let current = outputs.first(where: { $0.id == currentID && $0.bluetooth }) { track(current) }
            else if paired.count == 1, let device = paired.first { track(device) }
        }
        // Older versions saved only the audio UID. Resolve the Bluetooth identity
        // while it is available so a later release disconnects the right device.
        if watchedAddress == nil, let device = targetDevice {
            watchedAddress = device.addressString
            saveTarget()
        }
        let connected = isOnMac
        connectionCheck.observe(currentUID: targetOutput.flatMap { $0.id == currentID ? $0.uid : nil },
                                connected: targetDevice?.isConnected() == true)
        if previouslyOnMac == true, !connected, !busy, quietPrompts { onDeparture?(watchedName) }
        previouslyOnMac = connected
    }

    private func refreshPairedDevices() {
        guard !pairedLookupInProgress else { return }
        pairedLookupInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
                .filter { $0.deviceClassMajor == 4 }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pairedLookupInProgress = false
                self.paired = devices
                if self.connectionObserver == nil {
                    self.connectionObserver = IOBluetoothDevice.register(forConnectNotifications: self,
                        selector: #selector(self.bluetoothChanged(_:device:)))
                }
                if !self.hasHeadphones, devices.count == 1, let device = devices.first { self.track(device) }
                self.observeTargetDisconnect()
            }
        }
    }

    private func saveTarget() {
        UserDefaults.standard.set(watchedUID, forKey: "watchedUID")
        UserDefaults.standard.set(watchedName, forKey: "watchedName")
        UserDefaults.standard.set(watchedAddress, forKey: "watchedAddress")
    }

    func track(_ output: Output) {
        guard !busy else { return }
        resetSoundCheck()
        watchedUID = output.uid
        watchedName = output.name
        watchedAddress = paired.first(where: { matches(output, $0) })?.addressString
        previouslyOnMac = nil
        message = nil
        saveTarget()
        observeTargetDisconnect()
    }

    func track(_ device: IOBluetoothDevice) {
        guard !busy else { return }
        resetSoundCheck()
        let output = outputs.first { matches($0, device) }
        watchedAddress = device.addressString
        watchedUID = output?.uid
        watchedName = output?.name ?? device.name ?? "Your headphones"
        previouslyOnMac = nil
        message = nil
        saveTarget()
        observeTargetDisconnect()
    }

    func isTracked(_ device: IOBluetoothDevice) -> Bool { targetDevice?.addressString == device.addressString }

    private func matches(_ output: Output, _ device: IOBluetoothDevice) -> Bool {
        let address = (device.addressString ?? "").filter { $0.isHexDigit }.lowercased()
        let uid = output.uid.filter { $0.isHexDigit }.lowercased()
        return output.bluetooth && ((!address.isEmpty && uid.contains(address)) || output.name == device.name)
    }

    private func select(_ output: Output) { selectRoute(output, direction: .output) }

    private func selectRoute(_ device: Output, direction: AudioDirection) {
        guard !busy else { return }
        operationID = rowID(for: device); message = nil
        routingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operationID = nil; self.refresh() }
            do {
                try await self.routing.select(device.id, direction: direction)
                self.message = direction == .input ? "Microphone selected. Soundbound is not recording." :
                    (device.bluetooth ? "Mac output selected. Use Test sound to check your headphones." : "Mac output selected.")
            } catch { self.message = error.localizedDescription }
        }
    }

    func setVolume(_ uid: String, level: Double) {
        guard !busy, let device = outputs.first(where: { rowID(for: $0) == uid }) else { return }
        operationID = uid; message = nil
        routingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operationID = nil; self.refresh() }
            do { try await self.routing.setVolume(level, id: device.id) }
            catch { self.message = error.localizedDescription }
        }
    }

    func perform(_ action: LocalAudioAction, id: String) {
        guard !busy else { return }
        let output = outputs.first { rowID(for: $0) == id }
        let input = inputs.first { rowID(for: $0) == id }
        let bluetooth = paired.first { device in
            "bluetooth:" + (device.addressString ?? device.name ?? "unknown").lowercased() == id ||
                (output.map { self.matches($0, device) } ?? false)
        }
        switch action {
        case .useOutput:
            guard let output else { message = RoutingError.unavailable.localizedDescription; return }
            if output.bluetooth { track(output) }
            selectRoute(output, direction: .output)
        case .useInput:
            guard let input else { message = RoutingError.unavailable.localizedDescription; return }
            selectRoute(input, direction: .input)
        case .connect:
            if let bluetooth { track(bluetooth); useOnMac() }
            else if let address = watchedAddress, id == "bluetooth:" + address.lowercased() {
                connecting = true; message = nil
                let lookup = UUID()
                connectionLookup = lookup
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, self.connectionLookup == lookup else { return }
                    self.connectionLookup = nil
                    self.connecting = false
                    self.message = "Bluetooth did not respond. Check that Bluetooth is on and try again."
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let device = IOBluetoothDevice(addressString: address)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.connectionLookup == lookup else { return }
                        self.connectionLookup = nil
                        self.connecting = false
                        guard let device else { self.message = "Bluetooth could not find these headphones."; return }
                        self.paired.append(device)
                        self.track(device); self.useOnMac()
                    }
                }
            } else { message = "These headphones are not available. Connect them in Bluetooth settings first." }
        case .disconnect:
            if let output { track(output) } else if let bluetooth { track(bluetooth) }
            releaseForPhone()
        case .testSound:
            if let output { track(output) }
            testSound()
        case .testOutput:
            guard let output else { message = RoutingError.unavailable.localizedDescription; return }
            playOutputTest(output)
        case .heardSound: confirmSound(heard: true)
        case .didNotHearSound: confirmSound(heard: false)
        }
    }

    private func playOutputTest(_ output: Output) {
        guard !busy else { return }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(output.id)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000)!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                let t = Double(i) / 48_000
                let fade = max(0, min(1, min(t / 0.03, (0.25 - t) / 0.06)))
                let sample = Float(sin(2 * .pi * (660 * t - 440 * t * t)) * 0.03 * fade)
                buffer.floatChannelData![0][i] = sample; buffer.floatChannelData![1][i] = sample
            }
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
            verificationEngine = engine; verificationPlayer = player; operationID = rowID(for: output)
            try engine.start(); player.scheduleBuffer(buffer); player.play()
            message = "Playing a quiet test on \(output.name)."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.verificationEngine === engine else { return }
                self.resetSoundCheck(); self.operationID = nil
            }
        } catch { resetSoundCheck(); operationID = nil; message = error.localizedDescription }
    }

    func reconnect() { useOnMac() }

    func useOnMac() {
        guard !busy else { return }
        resetSoundCheck()
        refresh()
        if let output = targetOutput { select(output); return }
        guard let device = targetDevice else {
            message = "Open Setup and choose your headphones first."
            return
        }
        connecting = true
        pendingDevice = device
        message = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let status = device.isConnected() ? kIOReturnSuccess : device.openConnection(self)
            if status != kIOReturnSuccess {
                DispatchQueue.main.async { [weak self] in self?.finishFailure() }
            }
        }
        let deadline = Date().addingTimeInterval(12)
        attemptTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.refresh()
            if let output = self.outputs.first(where: { self.matches($0, device) }) {
                timer.invalidate()
                self.connecting = false
                self.pendingDevice = nil
                self.select(output)
                self.observeTargetDisconnect()
            } else if Date() >= deadline { self.finishFailure() }
        }
    }

    func releaseForPhone() {
        guard !busy else { return }
        resetSoundCheck()
        refresh()
        guard let device = targetDevice else {
            message = "I can’t identify the Bluetooth connection. Choose your headphones in Setup."
            return
        }
        guard isOnMac else {
            message = "On your iPhone, open Control Center, tap AirPlay, then choose your AirPods."
            return
        }
        releasing = true
        message = nil
        // Disconnect the actual Bluetooth device; changing to Mac speakers would
        // only reroute sound and would not release the headphones.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = device.closeConnection()
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == kIOReturnSuccess else {
                    self.releasing = false
                    self.message = "Couldn’t release your headphones. Try disconnecting them in Bluetooth settings."
                    self.refresh()
                    return
                }
                let deadline = Date().addingTimeInterval(5)
                self.attemptTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    self.refresh()
                    if !device.isConnected(), self.targetOutput == nil {
                        timer.invalidate()
                        self.releasing = false
                        self.message = "Released from this Mac. Now choose your AirPods in your iPhone’s Control Center."
                    } else if Date() >= deadline {
                        timer.invalidate()
                        self.releasing = false
                        self.message = "Your Mac still sees the headphones. Try again, or disconnect them in Bluetooth settings."
                    }
                }
            }
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingDevice?.addressString == device.addressString else { return }
            if status != kIOReturnSuccess { self.finishFailure() }
        }
    }

    private func finishFailure() {
        attemptTimer?.invalidate()
        connecting = false
        pendingDevice = nil
        message = "Couldn’t connect. Keep your headphones nearby and try again."
    }

    func resetSoundCheck() {
        verificationPlayer?.stop()
        verificationEngine?.stop()
        verificationPlayer = nil
        verificationEngine = nil
        connectionCheck.reset()
    }

    func testSound() {
        guard !busy else { return }
        resetSoundCheck()
        refresh()
        guard let output = targetOutput, output.id == Audio.current,
              targetDevice?.isConnected() == true else {
            message = "The Mac hasn’t established the connection. Try ‘Use on this Mac’ first."
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            // Pin the test to the selected headphones, never the fallback speakers.
            try engine.outputNode.auAudioUnit.setDeviceID(output.id)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<Int(buffer.frameLength) {
                let t = Double(frame) / 48_000
                let fade = max(0, min(1, min(t / 0.03, (0.5 - t) / 0.03)))
                let value = Float(sin(t * 2 * .pi * 440) * 0.04 * fade)
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            verificationEngine = engine
            verificationPlayer = player
            connectionCheck.begin(uid: output.uid)
            message = nil
            try engine.start()
            player.scheduleBuffer(buffer)
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.verificationEngine === engine else { return }
                player.stop()
                engine.stop()
                self.verificationPlayer = nil
                self.verificationEngine = nil
                self.refresh()
                self.connectionCheck.finished()
            }
        } catch {
            resetSoundCheck()
            message = "The sound test couldn’t start. Takeover is not confirmed."
        }
    }

    func confirmSound(heard: Bool) {
        refresh()
        let currentUID = targetOutput?.id == Audio.current ? targetOutput?.uid : nil
        connectionCheck.answer(heard: heard, currentUID: currentUID)
        message = hasVerifiedSound ? nil : "Takeover not confirmed. Your iPhone may still have the AirPods."
    }
}
