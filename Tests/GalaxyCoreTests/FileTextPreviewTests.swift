import Foundation
import XCTest
@testable import GalaxyCore

final class FileTextPreviewTests: XCTestCase {
    func testPreviewsNormalizeWindowsUnicodeTextAndKeepLineEndings() throws {
        let expected = "한글,값\r\n둘째,👩‍💻 ㄱ\r\n"
        let decomposed = expected.decomposedStringWithCanonicalMapping
        let encodings: [([UInt8], String.Encoding)] = [
            ([], .utf8), ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE, 0, 0], .utf32LittleEndian), ([0, 0, 0xFE, 0xFF], .utf32BigEndian),
        ]
        let folder = try temporaryFolder()
        XCTAssertTrue(FileTextPreview.supports("TXT"))
        XCTAssertTrue(FileTextPreview.supports("CSV"))
        for (index, (mark, encoding)) in encodings.enumerated() {
            let copy = folder.appendingPathComponent("한글 \(index).CSV")
            try (Data(mark) + XCTUnwrap(decomposed.data(using: encoding))).write(to: copy)
            let result = try FileTextPreview.prepare(copy)
            XCTAssertEqual(result, copy)
            XCTAssertEqual(try Data(contentsOf: result), Data(expected.utf8))
        }
    }

    #if os(macOS)
    func testCP949IncludesSyllablesOutsideEUCKR() throws {
        let copy = try temporaryFolder().appendingPathComponent("윈도우.TXT")
        try Data([0x8C, 0x63, 0xC6, 0x52, 0x0D, 0x0A]).write(to: copy)
        let result = try FileTextPreview.prepare(copy)
        XCTAssertEqual(try Data(contentsOf: result), Data("똠힣\r\n".utf8))
    }
    #endif

    func testMalformedUnicodeLeavesTheNativeTextPreviewCopyIntact() throws {
        let copy = try temporaryFolder().appendingPathComponent("파일.txt")
        let original = Data([0xFF, 0xFE, 0x00])
        try original.write(to: copy)
        let result = try FileTextPreview.prepare(copy)
        XCTAssertEqual(try Data(contentsOf: result), original)
    }

    func testDOCXComposesTextAcrossRunsAndKeepsBreaks() throws {
        let copy = try officeCopy("DOCX", parts: ["word/document.xml": """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
              <w:p><w:r><w:t>&#x1112;&#x1161;</w:t></w:r><w:r><w:t>&#x11AB;</w:t><w:tab/><w:t>글 &amp; 표</w:t></w:r></w:p>
              <w:p><w:r><w:t>다음</w:t><w:br/><w:t>줄</w:t></w:r></w:p>
            </w:body></w:document>
            """])
        try assertPreview(copy, text: "한\t글 & 표\n다음\n줄")
    }

    func testXLSXResolvesSharedAndInlineStringsBeforeNormalizing() throws {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let copy = try officeCopy("xlsx", parts: [
            "xl/workbook.xml": """
                <workbook xmlns="\(ns)" xmlns:r="\(office)"><sheets><sheet r:id="rId2"/><sheet r:id="rId1"/></sheets></workbook>
                """,
            "xl/_rels/workbook.xml.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Type="\(office)/worksheet" Target="worksheets/sheet1.xml"/>
                  <Relationship Id="rId2" Type="\(office)/worksheet" Target="/xl/worksheets/sheet2.xml"/>
                </Relationships>
                """,
            "xl/sharedStrings.xml": """
                <sst xmlns="\(ns)"><si><r><t>&#x1112;</t></r><r><t>&#x1161;&#x11AB;</t></r><rPh sb="0" eb="1"><t>발음</t></rPh></si></sst>
                """,
            "xl/worksheets/sheet1.xml": """
                <worksheet xmlns="\(ns)"><sheetData><row><c t="s"><v>0</v></c><c t="inlineStr"><is><t>_x1100__x1173__x11AF_</t></is></c></row>
                <row><c><v>42</v></c></row></sheetData></worksheet>
                """,
            "xl/worksheets/sheet2.xml": """
                <worksheet xmlns="\(ns)"><sheetData><row><c t="inlineStr"><is><t>먼저</t></is></c></row></sheetData></worksheet>
                """,
        ])
        try assertPreview(copy, text: "먼저\n\n한\t글\n42")
    }

    func testPPTXShowsComposedTextOnConsecutiveSlides() throws {
        let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let prefix = "<p:sld xmlns:p=\"\(presentation)\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><p:cSld>"
        let suffix = "</p:cSld></p:sld>"
        let copy = try officeCopy("PPTX", parts: [
            "ppt/presentation.xml": """
                <p:presentation xmlns:p="\(presentation)" xmlns:r="\(office)"><p:sldIdLst><p:sldId r:id="rId10"/><p:sldId r:id="rId2"/></p:sldIdLst></p:presentation>
                """,
            "ppt/_rels/presentation.xml.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId2" Type="\(office)/slide" Target="slides/slide2.xml"/>
                  <Relationship Id="rId10" Type="\(office)/slide" Target="slides/slide10.xml"/>
                </Relationships>
                """,
            "ppt/slides/slide10.xml": prefix + "<a:p><a:r><a:t>&#x1100;&#x1173;&#x11AF;</a:t></a:r></a:p>" + suffix,
            "ppt/slides/slide2.xml": prefix + "<a:p><a:r><a:t>&#x1112;</a:t></a:r><a:r><a:t>&#x1161;&#x11AB;</a:t></a:r></a:p>" + suffix,
        ])
        try assertPreview(copy, text: "글\n\n한")
    }

    func testOfficePreviewRejectsDocumentTypeDeclarations() throws {
        let copy = try officeCopy("docx", parts: ["word/document.xml": """
            <!DOCTYPE document [<!ENTITY text "한글">]><document>&text;</document>
            """])
        XCTAssertThrowsError(try FileTextPreview.prepare(copy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingPathExtension().appendingPathExtension("txt").path))
    }

    private func assertPreview(_ copy: URL, text: String) throws {
        let original = try Data(contentsOf: copy)
        let preview = try FileTextPreview.prepare(copy)
        XCTAssertEqual(preview.pathExtension, "txt")
        XCTAssertEqual(try Data(contentsOf: preview), Data(text.utf8))
        XCTAssertEqual(try Data(contentsOf: copy), original)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func officeCopy(_ fileExtension: String, parts: [String: String]) throws -> URL {
        try XCTSkipUnless(["/usr/bin/zip", "/usr/bin/unzip"].allSatisfy { FileManager.default.isExecutableFile(atPath: $0) })
        let folder = try temporaryFolder()
        for (path, xml) in parts {
            let part = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: part)
        }
        let copy = folder.appendingPathComponent("한글 보고서.\(fileExtension)")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", copy.path] + parts.keys.sorted()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return copy
    }
}
