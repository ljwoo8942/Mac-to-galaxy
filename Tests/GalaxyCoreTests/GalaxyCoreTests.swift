import Foundation
import XCTest
@testable import GalaxyCore

final class GalaxyCoreTests: XCTestCase {
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
