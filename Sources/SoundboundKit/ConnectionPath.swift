import Network
#if os(macOS)
import IOKit
#endif

/// Interface information exposed by Network.framework, not proof of a direct LAN route.
/// Bonjour discovers the peer; it is not the media transport.
public enum LocalConnectionPath: String, Hashable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case usb = "USB networking"
    case cellular = "Cellular"
    case loopback = "Loopback"
    case tunnel = "Tunnel interface (possible VPN)"
    case other = "Interface unknown"

    /// The name short enough for a device row.
    var shortLabel: String {
        switch self {
        case .usb: return "USB"
        case .tunnel: return "Tunnel"
        case .other: return "Network"
        default: return rawValue
        }
    }

    static func isTunnelInterface(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "gif"].contains { name.hasPrefix($0) }
    }

    #if os(macOS)
    static func isUSBInterface(_ name: String) -> Bool {
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return false }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard entry != 0 else { return false }
        defer { if entry != 0 { IOObjectRelease(entry) } }
        for _ in 0..<24 {
            var className = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(entry, &className) == KERN_SUCCESS, String(cString: className).contains("USB") { return true }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
            IOObjectRelease(entry); entry = parent
        }
        return false
    }
    #endif

    init(_ path: NWPath?) {
        if let name = path?.availableInterfaces.first?.name,
           Self.isTunnelInterface(name) { self = .tunnel }
        else if path?.usesInterfaceType(.wiredEthernet) == true {
            #if os(macOS)
            self = path?.availableInterfaces.contains(where: { $0.type == .wiredEthernet && Self.isUSBInterface($0.name) }) == true ? .usb : .ethernet
            #else
            self = .ethernet
            #endif
        }
        else if path?.usesInterfaceType(.wifi) == true { self = .wifi }
        else if path?.usesInterfaceType(.cellular) == true { self = .cellular }
        else if path?.usesInterfaceType(.loopback) == true { self = .loopback }
        else { self = .other }
    }
}

struct ConnectionRouteDetails {
    let text: String
    init(_ connection: NWConnection) {
        let path = connection.currentPath
        let interfaces = path?.availableInterfaces.map { "\($0.name) (\($0.type))" }.joined(separator: ", ") ?? "unavailable"
        text = "Local: \(path?.localEndpoint.map { String(describing: $0) } ?? "unavailable")\nRemote: \(path?.remoteEndpoint.map { String(describing: $0) } ?? String(describing: connection.endpoint))\nPath interfaces: \(interfaces)\nRoute: \(path.map { String(describing: $0) } ?? "unavailable")\nRouter hops and VPN exit are not exposed by this API."
    }
}
