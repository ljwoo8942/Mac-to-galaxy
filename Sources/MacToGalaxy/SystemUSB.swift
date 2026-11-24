import Darwin
import Foundation
import GalaxyCore
import IOKit
import SystemConfiguration

struct SystemUSB {
    static func devices() -> [GalaxyDevice] {
        var modes: [UInt64: Set<USBNetworkMode>] = [:]
        var interfaces: [UInt64: Set<UInt64>] = [:]
        var massStorageDevices: Set<UInt64> = []
        forEachService("IOUSBHostInterface") { entry in
            guard let deviceID = usbDeviceID(above: entry) else { return }
            if let id = registryID(entry) {
                interfaces[deviceID, default: []].insert(id)
            }
            guard let classCode = number(entry, "bInterfaceClass")?.uint8Value else { return }
            if classCode == 0x08 {
                massStorageDevices.insert(deviceID)
            }
            if let subclass = number(entry, "bInterfaceSubClass")?.uint8Value,
               let protocolCode = number(entry, "bInterfaceProtocol")?.uint8Value,
               let mode = USBNetworkMode(classCode: classCode, subclass: subclass, protocolCode: protocolCode) {
                modes[deviceID, default: []].insert(mode)
            }
        }

        var devices: [GalaxyDevice] = []
        forEachService("IOUSBHostDevice") { entry in
            guard number(entry, "idVendor")?.uint16Value == GalaxyDevice.samsungVendorID,
                  let productID = number(entry, "idProduct")?.uint16Value,
                  let id = registryID(entry), !massStorageDevices.contains(id) else { return }
            let productName = property(entry, "USB Product Name") as? String
            devices.append(GalaxyDevice(registryID: id, productID: productID,
                                        name: productName ?? "갤럭시", interfaceIDs: interfaces[id] ?? [],
                                        networkModes: modes[id] ?? []))
        }
        return devices
    }

    static func networkInterfaces(for device: GalaxyDevice) -> [USBNetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        var names: [String: Bool] = [:]
        var addresses: [String: Set<String>] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = head
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            guard let address = interface.ifa_addr, let name = interface.ifa_name else { continue }
            let bsdName = String(cString: name)
            names[bsdName] = (interface.ifa_flags & UInt32(IFF_UP)) != 0
            if let ip = usableAddress(address) {
                addresses[bsdName, default: []].insert(ip)
            }
        }

        return names.compactMap { name, isUp in
            guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return nil }
            let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard entry != 0 else { return nil }
            defer { IOObjectRelease(entry) }
            guard usbDeviceID(above: entry) == device.registryID else { return nil }
            return USBNetworkInterface(name: name, deviceID: device.registryID, isUp: isUp, addresses: addresses[name] ?? [])
        }
    }

    static func primaryNetworkInterfaces() -> [String: String] {
        let ipv4 = "State:/Network/Global/IPv4"
        let ipv6 = "State:/Network/Global/IPv6"
        let keys = [ipv4, ipv6] as CFArray
        guard let states = SCDynamicStoreCopyMultiple(nil, keys, nil) as? [String: [String: Any]] else { return [:] }

        let primaryInterface = kSCDynamicStorePropNetPrimaryInterface as String
        var interfaces: [String: String] = [:]
        interfaces["IPv4"] = states[ipv4]?[primaryInterface] as? String
        interfaces["IPv6"] = states[ipv6]?[primaryInterface] as? String
        return interfaces
    }

    private static func usableAddress(_ address: UnsafePointer<sockaddr>) -> String? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let ip = UInt32(bigEndian: raw)
            let firstOctet = ip >> 24
            guard firstOctet != 0, firstOctet != 127, firstOctet < 224, ip >> 16 != 0xa9fe else { return nil }
        case AF_INET6:
            let raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            let isRoutable = withUnsafeBytes(of: raw) { bytes in
                (bytes[0] & 0xe0) == 0x20 || (bytes[0] & 0xfe) == 0xfc
            }
            guard isRoutable else { return nil }
        default:
            return nil
        }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
        return result == 0 ? String(cString: host) : nil
    }

    private static func usbDeviceID(above entry: io_registry_entry_t) -> UInt64? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        if IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 {
            return registryID(parent)
        }
        return usbDeviceID(above: parent)
    }

    private static func forEachService(_ className: String, visit: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            visit(entry)
            IOObjectRelease(entry)
        }
    }

    private static func registryID(_ entry: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS ? id : nil
    }

    private static func number(_ entry: io_registry_entry_t, _ key: String) -> NSNumber? {
        property(entry, key) as? NSNumber
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
