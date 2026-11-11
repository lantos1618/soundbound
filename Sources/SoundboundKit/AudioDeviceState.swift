import Foundation

/// OS observations and user intent are independent. A successful request is
/// never treated as proof that the route changed.
public struct AudioDeviceState: Equatable {
    public enum Observed: Equatable { case disconnected, available, input, output, inputAndOutput }
    public enum Intent: Equatable { case none, connect, disconnect, useInput, useOutput }
    public enum Transition: Equatable { case settled, pending, failed }
    public private(set) var observed: Observed = .disconnected
    public private(set) var intent: Intent = .none
    public private(set) var transition: Transition = .settled
    private var requestedAt: Date?

    public mutating func request(_ intent: Intent, now: Date = Date()) {
        self.intent = intent
        requestedAt = intent == .none ? nil : now
        transition = intent == .none ? .settled : .pending
    }

    public mutating func observe(_ device: LocalAudioDevice?, now: Date = Date()) {
        if let device, device.isAvailable {
            observed = device.selectedInput && device.selectedOutput ? .inputAndOutput :
                device.selectedOutput ? .output : device.selectedInput ? .input : .available
        } else { observed = .disconnected }
        guard transition != .settled else { return }
        let confirmed: Bool
        switch intent {
        case .none: confirmed = true
        case .connect: confirmed = observed != .disconnected
        case .disconnect: confirmed = observed == .disconnected
        case .useInput: confirmed = observed == .input || observed == .inputAndOutput
        case .useOutput: confirmed = observed == .output || observed == .inputAndOutput
        }
        if confirmed { transition = .settled; intent = .none; requestedAt = nil }
        else if let requestedAt, now.timeIntervalSince(requestedAt) >= 15 { transition = .failed }
    }
}

public enum AudioDeviceInventory {
    /// Normalize only explicit Bluetooth addresses, never display names.
    public static func bluetoothIdentity(_ address: String) -> String? {
        let compact = address.lowercased().filter { $0 != ":" && $0 != "-" }
        guard compact.count == 12, compact.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "bluetooth:" + compact
    }

    public static func identity(of device: LocalAudioDevice) -> String {
        if let physicalID = device.physicalID, !physicalID.isEmpty { return physicalID }
        if device.id.hasPrefix("bluetooth:"), let id = bluetoothIdentity(String(device.id.dropFirst(10))) { return id }
        return device.id
    }

    /// Fold repeated reports and input/output profiles for the same proven
    /// identity into one row. Distinct devices with equal names stay distinct.
    public static func reconcile(_ devices: [LocalAudioDevice]) -> [LocalAudioDevice] {
        var order: [String] = [], groups: [String: [LocalAudioDevice]] = [:], identitiesByID: [String: String] = [:]
        for device in devices where !device.id.isEmpty {
            let key = identitiesByID[device.id] ?? identity(of: device)
            identitiesByID[device.id] = key
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(device)
        }
        return order.compactMap { key in
            guard let group = groups[key], var result = group.max(by: { rank($0) < rank($1) }) else { return nil }
            result.hasInput = group.contains { $0.hasInput }
            result.hasOutput = group.contains { $0.hasOutput }
            result.selectedInput = group.contains { $0.isAvailable && $0.selectedInput }
            result.selectedOutput = group.contains { $0.isAvailable && $0.selectedOutput }
            result.isAvailable = group.contains { $0.isAvailable }
            result.isChecking = group.contains { $0.isChecking }
            result.busy = group.contains { $0.busy }
            result.canConnect = group.contains { $0.canConnect }
            result.canDisconnect = group.contains { $0.canDisconnect }
            result.systemInputID = group.first(where: { $0.systemInputID != nil })?.systemInputID
            result.systemOutputID = group.first(where: { $0.systemOutputID != nil })?.systemOutputID
            return result
        }
    }
    private static func rank(_ device: LocalAudioDevice) -> Int {
        (device.isAvailable ? 16 : 0) + (device.selectedOutput ? 8 : 0) + (device.hasOutput ? 4 : 0) + (device.selectedInput ? 2 : 0) + (device.hasInput ? 1 : 0)
    }
}
