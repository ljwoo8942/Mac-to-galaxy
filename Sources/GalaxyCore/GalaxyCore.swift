import Foundation

public enum USBNetworkMode: String, CaseIterable, Sendable {
    case rndis = "RNDIS"
    case ncm = "CDC-NCM"
    case ecm = "CDC-ECM"

    public init?(classCode: UInt8, subclass: UInt8, protocolCode: UInt8) {
        switch (classCode, subclass, protocolCode) {
        case (0xe0, 0x01, 0x03), (0x02, 0x02, 0xff):
            self = .rndis
        case (0x02, 0x0d, _):
            self = .ncm
        case (0x02, 0x06, _):
            self = .ecm
        default:
            return nil
        }
    }
}

public struct GalaxyDevice: Equatable, Sendable {
    public static let samsungVendorID: UInt16 = 0x04e8

    public let registryID: UInt64
    public let productID: UInt16
    public let name: String
    public let interfaceIDs: Set<UInt64>
    public let networkModes: Set<USBNetworkMode>

    public init(registryID: UInt64, productID: UInt16, name: String,
                interfaceIDs: Set<UInt64>, networkModes: Set<USBNetworkMode>) {
        self.registryID = registryID
        self.productID = productID
        self.name = name
        self.interfaceIDs = interfaceIDs
        self.networkModes = networkModes
    }
}

public struct USBNetworkInterface: Equatable, Sendable {
    public let name: String
    public let deviceID: UInt64
    public let isUp: Bool
    public let addresses: Set<String>

    public init(name: String, deviceID: UInt64, isUp: Bool, addresses: Set<String>) {
        self.name = name
        self.deviceID = deviceID
        self.isUp = isUp
        self.addresses = addresses
    }

    var hasAddress: Bool { isUp && !addresses.isEmpty }
}

public enum TetheringState: Equatable, Sendable {
    case noDevice
    case selectOneDevice
    case waitingForTethering
    case noNetworkInterface(Set<USBNetworkMode>)
    case waitingForAddress(USBNetworkInterface)
    case addressed(USBNetworkInterface)

    public init(devices: [GalaxyDevice], interfaces: [USBNetworkInterface]) {
        guard let device = devices.first else {
            self = .noDevice
            return
        }
        guard devices.count == 1 else {
            self = .selectOneDevice
            return
        }

        let matching = interfaces.filter { $0.deviceID == device.registryID }
            .sorted { $0.name < $1.name }
        if let usable = matching.first(where: \.hasAddress) {
            self = .addressed(usable)
        } else if let networkInterface = matching.first {
            self = .waitingForAddress(networkInterface)
        } else if !device.networkModes.isEmpty {
            self = .noNetworkInterface(device.networkModes)
        } else {
            self = .waitingForTethering
        }
    }
}

public struct GalaxyEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case storage, folder, file }

    public let id: UInt32
    public let name: String
    public let kind: Kind
    public let size: UInt64

    public init(id: UInt32, name: String, kind: Kind, size: UInt64 = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
    }

    public var localFilename: String {
        let lastComponent = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        let cleaned = lastComponent?.components(separatedBy: .controlCharacters).joined() ?? ""
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Galaxy-\(id)" : cleaned
    }
}

public enum InternetProbeResponse: Equatable {
    case incomplete
    case success
    case unexpected

    public init(buffer: Data) {
        guard let lineEnd = buffer.range(of: Data([13, 10]))?.lowerBound else {
            self = buffer.count < 4096 ? .incomplete : .unexpected
            return
        }
        let statusLine = String(decoding: buffer.prefix(upTo: lineEnd), as: UTF8.self)
        let fields = statusLine.split(separator: " ", maxSplits: 2)
        self = fields.count >= 2 && ["HTTP/1.0", "HTTP/1.1"].contains(fields[0]) && fields[1] == "204"
            ? .success : .unexpected
    }
}
