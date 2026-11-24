import Foundation

public struct GalaxyDevice: Equatable, Sendable {
    public static let samsungVendorID: UInt16 = 0x04e8

    public let registryID: UInt64
    public let productID: UInt16
    public let name: String
    public let interfaceIDs: Set<UInt64>

    public init(registryID: UInt64, productID: UInt16, name: String,
                interfaceIDs: Set<UInt64>) {
        self.registryID = registryID
        self.productID = productID
        self.name = name
        self.interfaceIDs = interfaceIDs
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

    public static func uploadFilename(_ name: String) -> String? {
        let filename = name.precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet(charactersIn: "/\\<>:\"|?*").union(.controlCharacters)
        guard !filename.isEmpty, filename != ".", filename != "..",
              filename.utf16.count <= 254, filename.utf8.count <= 255,
              filename.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return filename
    }

    public func conflictsWithUpload(named filename: String) -> Bool {
        name.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(filename) == .orderedSame
    }
}
