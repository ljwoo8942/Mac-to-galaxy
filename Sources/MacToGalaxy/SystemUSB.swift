import Foundation
import GalaxyCore
import IOKit

struct SystemUSB {
    static func devices() -> [GalaxyDevice] {
        var interfaces: [UInt64: Set<UInt64>] = [:]
        var massStorageDevices: Set<UInt64> = []
        forEachService("IOUSBHostInterface") { entry in
            guard let deviceID = usbDeviceID(above: entry) else { return }
            if let id = registryID(entry) {
                interfaces[deviceID, default: []].insert(id)
            }
            if number(entry, "bInterfaceClass")?.uint8Value == 0x08 {
                massStorageDevices.insert(deviceID)
            }
        }

        var devices: [GalaxyDevice] = []
        forEachService("IOUSBHostDevice") { entry in
            guard number(entry, "idVendor")?.uint16Value == GalaxyDevice.samsungVendorID,
                  let productID = number(entry, "idProduct")?.uint16Value,
                  let id = registryID(entry), !massStorageDevices.contains(id) else { return }
            let productName = property(entry, "USB Product Name") as? String
            devices.append(GalaxyDevice(registryID: id, productID: productID,
                                        name: productName ?? "갤럭시", interfaceIDs: interfaces[id] ?? []))
        }
        return devices
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
