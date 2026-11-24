import CoreFoundation
import Foundation
#if os(macOS)
import Darwin
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum FileTextPreview {
    private enum OfficeFormat: String {
        case docx, xlsx, pptx
    }

    private static let textLimit = 8 * 1024 * 1024
    private static let officeLimit = 64 * 1024 * 1024

    public static func supports(_ fileExtension: String) -> Bool {
        let fileExtension = fileExtension.lowercased()
        return OfficeFormat(rawValue: fileExtension) != nil || ["txt", "csv", "tsv", "log", "ini"].contains(fileExtension)
    }

    public static func prepare(_ previewCopy: URL) throws -> URL {
        let size = try previewCopy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let format = OfficeFormat(rawValue: previewCopy.pathExtension.lowercased()) {
            guard size <= officeLimit else { throw PreviewError.officeTooLarge }
            let text = try officeText(in: previewCopy, format: format)
            let output = previewCopy.deletingPathExtension().appendingPathExtension("txt")
            try writeOfficePreview(Data(text.precomposedStringWithCanonicalMapping.utf8), to: output)
            return output
        }

        // shortcut: large or unrecognized text uses the native preview, revisit if streamed normalization is needed.
        guard size <= textLimit else { return previewCopy }
        let original = try Data(contentsOf: previewCopy)
        if let text = decode(original, allowKoreanLegacyEncoding: true) {
            let normalized = Data(text.precomposedStringWithCanonicalMapping.utf8)
            if normalized != original { try normalized.write(to: previewCopy, options: .atomic) }
        }
        return previewCopy
    }

    private static func writeOfficePreview(_ data: Data, to output: URL) throws {
        #if os(macOS)
        let fd = open(output.pathWithNFCFilename, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
        #else
        try data.write(to: output, options: .withoutOverwriting)
        #endif
    }

    private static func decode(_ data: Data, allowKoreanLegacyEncoding: Bool) -> String? {
        let byteOrderMarks: [([UInt8], String.Encoding)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian), ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFE, 0xFF], .utf16BigEndian), ([0xFF, 0xFE], .utf16LittleEndian),
        ]
        if let (mark, encoding) = byteOrderMarks.first(where: { data.starts(with: $0.0) }) {
            let payload = data.dropFirst(mark.count)
            guard let text = String(data: payload, encoding: encoding),
                  text.data(using: encoding) == payload, !text.utf8.contains(0) else { return nil }
            return text
        }
        guard !data.contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        #if os(macOS)
        if allowKoreanLegacyEncoding {
            let korean = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(korean))
            if let text = String(data: data, encoding: encoding),
               text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
                return text
            }
        }
        #endif
        return nil
    }

    private static func officeText(in file: URL, format: OfficeFormat) throws -> String {
        let listing = try unzip(["-Z1", file.path], limit: 256 * 1024)
        let parts = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
        let names = Set(parts)
        guard names.count == parts.count else { throw PreviewError.unreadableOffice }
        var xmlBytesLeft = textLimit
        func xml(_ part: String) throws -> XMLDocument {
            guard names.contains(part) else { throw PreviewError.unreadableOffice }
            let data = try unzip(["-p", file.path, part], limit: xmlBytesLeft)
            xmlBytesLeft -= data.count
            guard let text = decode(data, allowKoreanLegacyEncoding: false), !text.contains("<!DOCTYPE") else {
                throw PreviewError.unreadableOffice
            }
            return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace])
        }

        var content = ""
        var bytesLeft = textLimit
        func append(_ text: String) throws {
            bytesLeft -= text.utf8.count
            guard bytesLeft >= 0 else { throw PreviewError.officeTooLarge }
            content += text
        }

        func appendParagraphs(_ document: XMLDocument, namespaces: Set<String>) throws {
            let nodes = try document.nodes(forXPath: "//*[local-name()='p' or local-name()='t' or local-name()='tab' or local-name()='br' or local-name()='cr']")
            var seenParagraph = false
            for node in nodes {
                guard let uri = node.uri, namespaces.contains(uri) else { continue }
                switch node.localName {
                case "p":
                    if seenParagraph { try append("\n") }
                    seenParagraph = true
                case "t": try append(node.stringValue ?? "")
                case "tab" where node.parent?.localName == "r": try append("\t")
                case "br", "cr": try append("\n")
                default: break
                }
            }
        }

        func orderedParts(_ manifest: String, element: String, kind: String) throws -> [String] {
            let directory = (manifest as NSString).deletingLastPathComponent
            let relationships = "\(directory)/_rels/\((manifest as NSString).lastPathComponent).rels"
            let ids = try xml(manifest).nodes(forXPath: "//*[local-name()='\(element)']/@*[local-name()='id']").filter { node in
                node.uri == "http://schemas.openxmlformats.org/officeDocument/2006/relationships" ||
                    node.uri == "http://purl.oclc.org/ooxml/officeDocument/relationships"
            }
            guard ids.count <= 128 else { throw PreviewError.officeTooLarge }
            if ids.isEmpty { return [] }

            var related: [String: String] = [:]
            for node in try xml(relationships).nodes(forXPath: "/*[local-name()='Relationships']/*[local-name()='Relationship']") {
                guard let link = node as? XMLElement,
                      link.attribute(forName: "Type")?.stringValue?.hasSuffix("/" + kind) == true,
                      link.attribute(forName: "TargetMode")?.stringValue != "External",
                      let id = link.attribute(forName: "Id")?.stringValue,
                      let target = link.attribute(forName: "Target")?.stringValue else { continue }
                let part = target.hasPrefix("/") ? String(target.dropFirst()) : "\(directory)/\(target)"
                // unzip recognizes options after the archive path.
                let safe = !part.hasPrefix("-") && part.hasSuffix(".xml") &&
                    part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "./_-".contains($0)) }
                guard safe, names.contains(part), related[id] == nil else { throw PreviewError.unreadableOffice }
                related[id] = part
            }
            return ids.compactMap { $0.stringValue.flatMap { related[$0] } }
        }

        switch format {
        case .docx:
            try appendParagraphs(xml("word/document.xml"), namespaces: [
                "http://schemas.openxmlformats.org/wordprocessingml/2006/main", "http://purl.oclc.org/ooxml/wordprocessingml/main",
            ])
        case .pptx:
            let slides = try orderedParts("ppt/presentation.xml", element: "sldId", kind: "slide")
            for (index, part) in slides.enumerated() {
                if index > 0 { try append("\n\n") }
                try appendParagraphs(xml(part), namespaces: [
                    "http://schemas.openxmlformats.org/drawingml/2006/main", "http://purl.oclc.org/ooxml/drawingml/main",
                ])
            }
        case .xlsx:
            let sharedStrings = "xl/sharedStrings.xml"
            let shared = names.contains(sharedStrings)
                ? try xml(sharedStrings).nodes(forXPath: "/*[local-name()='sst']/*[local-name()='si']").map(spreadsheetRichText) : []
            let sheets = try orderedParts("xl/workbook.xml", element: "sheet", kind: "worksheet")
            for (sheetIndex, part) in sheets.enumerated() {
                if sheetIndex > 0 { try append("\n\n") }
                let rows = try xml(part).nodes(forXPath: "/*[local-name()='worksheet']/*[local-name()='sheetData']/*[local-name()='row']")
                for (index, row) in rows.enumerated() {
                    if index > 0 { try append("\n") }
                    let cells = try row.nodes(forXPath: "./*[local-name()='c']")
                    for (column, cell) in cells.enumerated() {
                        if column > 0 { try append("\t") }
                        try append(cellText(cell, shared: shared))
                    }
                }
            }
        }
        return content
    }

    private static func spreadsheetRichText(_ node: XMLNode) throws -> String {
        let text = try node.nodes(forXPath: "./*[local-name()='t'] | ./*[local-name()='r']/*[local-name()='t']")
            .compactMap(\.stringValue).joined()
        return decodeSpreadsheetText(text)
    }

    private static func cellText(_ node: XMLNode, shared: [String]) throws -> String {
        let cell = node as? XMLElement
        let kind = cell?.attribute(forName: "t")?.stringValue
        if kind == "inlineStr", let inline = try node.nodes(forXPath: "./*[local-name()='is']").first {
            return try spreadsheetRichText(inline)
        }
        let value = try node.nodes(forXPath: "./*[local-name()='v']").first?.stringValue ?? ""
        guard kind == "s" else { return kind == "str" ? decodeSpreadsheetText(value) : value }
        guard let index = Int(value), shared.indices.contains(index) else { throw PreviewError.unreadableOffice }
        return shared[index]
    }

    private static let spreadsheetEscape = try! NSRegularExpression(pattern: #"_x([0-9A-Fa-f]{4})_"#)

    private static func decodeSpreadsheetText(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        let source = text as NSString
        var units: [UInt16] = []
        var end = 0
        for match in spreadsheetEscape.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let start = match.range.location
            units.append(contentsOf: source.substring(with: NSRange(location: end, length: start - end)).utf16)
            if let unit = UInt16(source.substring(with: match.range(at: 1)), radix: 16) { units.append(unit) }
            end = NSMaxRange(match.range)
        }
        units.append(contentsOf: source.substring(from: end).utf16)
        return String(decoding: units, as: UTF16.self)
    }

    private static func unzip(_ arguments: [String], limit: Int) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        var result = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= limit - result.count else { throw PreviewError.officeTooLarge }
            result.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PreviewError.unreadableOffice }
        return result
    }

    private enum PreviewError: LocalizedError {
        case officeTooLarge, unreadableOffice

        var errorDescription: String? {
            switch self {
            case .officeTooLarge: return "문서가 미리보기 한도를 초과했습니다. ‘Mac에 저장’으로 파일을 열어 주세요."
            case .unreadableOffice: return "이 문서의 본문을 미리 볼 수 없습니다. ‘Mac에 저장’으로 파일을 열어 주세요."
            }
        }
    }
}
