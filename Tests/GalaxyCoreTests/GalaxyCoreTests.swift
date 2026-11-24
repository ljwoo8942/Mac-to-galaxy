import Foundation
import XCTest
@testable import GalaxyCore

final class GalaxyCoreTests: XCTestCase {
    private let galaxy = GalaxyDevice(registryID: 9, productID: 1, name: "Galaxy Z Flip7",
                                      interfaceIDs: [19], networkModes: [.rndis])

    func testOnlyAnInterfaceUnderTheGalaxyCanReportUSBConnectivity() {
        let otherAdapter = USBNetworkInterface(name: "en0", deviceID: 8, isUp: true, addresses: ["192.0.2.10"])
        XCTAssertEqual(TetheringState(devices: [galaxy], interfaces: [otherAdapter]), .noNetworkInterface([.rndis]))

        let unconfigured = USBNetworkInterface(name: "en4", deviceID: 9, isUp: false, addresses: ["192.0.2.20"])
        XCTAssertEqual(TetheringState(devices: [galaxy], interfaces: [otherAdapter, unconfigured]), .waitingForAddress(unconfigured))

        let ready = USBNetworkInterface(name: "en5", deviceID: 9, isUp: true, addresses: ["192.0.2.21"])
        XCTAssertEqual(TetheringState(devices: [galaxy], interfaces: [unconfigured, ready]), .addressed(ready))
    }

    func testTwoDevicesAreNeverTreatedAsOne() {
        let second = GalaxyDevice(registryID: 10, productID: 1, name: "Galaxy", interfaceIDs: [], networkModes: [])
        XCTAssertEqual(TetheringState(devices: [galaxy, second], interfaces: []), .selectOneDevice)
        XCTAssertEqual(TetheringState(devices: [], interfaces: []), .noDevice)
    }

    func testOnlyNetworkDescriptorsIdentifyATetheringMode() {
        XCTAssertEqual(USBNetworkMode(classCode: 0xe0, subclass: 0x01, protocolCode: 0x03), .rndis)
        XCTAssertEqual(USBNetworkMode(classCode: 0x02, subclass: 0x02, protocolCode: 0xff), .rndis)
        XCTAssertEqual(USBNetworkMode(classCode: 0x02, subclass: 0x0d, protocolCode: 0), .ncm)
        XCTAssertEqual(USBNetworkMode(classCode: 0x02, subclass: 0x06, protocolCode: 0), .ecm)
        XCTAssertNil(USBNetworkMode(classCode: 0x06, subclass: 0x01, protocolCode: 0x01))
    }

    func testInternetProbeAcceptsOnlyTheExpectedStatus() {
        XCTAssertEqual(InternetProbeResponse(buffer: Data("HTTP/1.1 204".utf8)), .incomplete)
        XCTAssertEqual(InternetProbeResponse(buffer: Data("HTTP/1.1 204 No Content\r\n".utf8)), .success)
        XCTAssertEqual(InternetProbeResponse(buffer: Data("HTTP/1.1 302 Found\r\n".utf8)), .unexpected)
        XCTAssertEqual(InternetProbeResponse(buffer: Data("HTTP/1.1 2040\r\n".utf8)), .unexpected)
    }

    func testPhoneObjectNamesCannotEscapeTheDownloadDirectory() {
        let file = GalaxyEntry(id: 42, name: "../../원본 사진.jpg", kind: .file)
        XCTAssertEqual(file.localFilename, "원본 사진.jpg")
        XCTAssertEqual(GalaxyEntry(id: 42, name: "../..", kind: .file).localFilename, "Galaxy-42")
    }

    func testUploadUsesNFCAndRejectsInvalidDeviceFilenames() {
        let filename = "한글 문서.hwp"
        let normalized = GalaxyEntry.uploadFilename(filename.decomposedStringWithCanonicalMapping)
        XCTAssertEqual(normalized?.utf8.map { $0 }, Array(filename.utf8))
        for invalid in ["", ".", "..", "../문서.hwp", "역\\슬래시.txt", "개행\n.txt", "잘못된:이름.txt",
                        String(repeating: "a", count: 255), String(repeating: "한", count: 86)] {
            XCTAssertNil(GalaxyEntry.uploadFilename(invalid))
        }
    }

    func testAnUploadConflictsWithCanonicalAndCaseVariantsOfFilesAndFolders() {
        let name = "한글 문서.txt"
        let original = GalaxyEntry(id: 42, name: name.decomposedStringWithCanonicalMapping.uppercased(), kind: .file)
        let folder = GalaxyEntry(id: 43, name: name, kind: .folder)
        XCTAssertTrue(original.conflictsWithUpload(named: name))
        XCTAssertTrue(folder.conflictsWithUpload(named: name))
        XCTAssertFalse(original.conflictsWithUpload(named: "다른 문서.txt"))
    }
}
