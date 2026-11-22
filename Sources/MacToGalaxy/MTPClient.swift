import Darwin
import Foundation
import GalaxyCore
import MTPBridge

enum MTPError: LocalizedError {
    case noFileTransfer
    case multipleDevices
    case cannotOpen
    case noStorage
    case notConnected
    case cannotRead
    case cancelled
    case incompleteCopy
    case destinationExists

    init(_ status: GalaxyMTPResult) {
        switch status {
        case GALAXY_MTP_UNAVAILABLE: self = .noFileTransfer
        case GALAXY_MTP_AMBIGUOUS: self = .multipleDevices
        case GALAXY_MTP_OPEN_FAILED: self = .cannotOpen
        case GALAXY_MTP_STORAGE_UNAVAILABLE: self = .noStorage
        case GALAXY_MTP_CANCELLED: self = .cancelled
        default: self = .cannotRead
        }
    }

    var errorDescription: String? {
        switch self {
        case .noFileTransfer: return "갤럭시의 USB 알림에서 ‘파일 전송’을 선택하세요."
        case .multipleDevices: return "갤럭시 한 대만 연결한 뒤 다시 시도하세요."
        case .cannotOpen: return "갤럭시에서 USB 접근을 허용하세요. Smart Switch 등 USB를 사용하는 다른 앱이 열려 있다면 종료하세요."
        case .noStorage: return "갤럭시 화면 잠금을 해제하고 휴대전화 데이터 접근을 허용하세요."
        case .notConnected: return "갤럭시의 파일 연결이 끊겼습니다."
        case .cannotRead: return "갤럭시에서 데이터를 읽지 못했습니다. USB 연결과 파일 전송 모드를 확인하세요."
        case .cancelled: return "파일 전송을 취소했습니다."
        case .incompleteCopy: return "전송된 파일 크기가 갤럭시의 원본과 달라 복사를 완료할 수 없습니다."
        case .destinationExists: return "같은 이름의 파일이 있습니다. 다른 이름이나 폴더를 선택하세요."
        }
    }
}

final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var fraction: Double?

    var snapshot: (cancelled: Bool, fraction: Double?) {
        lock.lock()
        defer { lock.unlock() }
        return (cancelled, fraction)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    fileprivate func update(completed: UInt64, total: UInt64) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if total > 0 {
            fraction = min(1, Double(completed) / Double(total))
        }
        return cancelled ? 1 : 0
    }
}

final class MTPClient {
    private final class EntryCollector {
        var entries: [GalaxyEntry] = []
    }

    private let queue = DispatchQueue(label: "MacToGalaxy.MTP", qos: .userInitiated)
    private var generation: UUID?
    private var session: OpaquePointer?

    deinit { galaxy_mtp_close(session) }

    func reset(to generation: UUID) {
        queue.async {
            self.close()
            self.generation = generation
        }
    }

    func connect(to device: GalaxyDevice, generation: UUID) async throws -> [GalaxyEntry] {
        try await perform {
            guard self.generation == generation else { throw MTPError.notConnected }
            self.close()
            var session: OpaquePointer?
            let result = galaxy_mtp_open(GalaxyDevice.samsungVendorID, device.productID, &session)
            guard result == GALAXY_MTP_OK, let session else { throw MTPError(result) }
            self.session = session
            do {
                return try self.readStorages(session)
            } catch {
                self.close()
                throw error
            }
        }
    }

    func storages(generation: UUID) async throws -> [GalaxyEntry] {
        try await perform {
            let session = try self.session(for: generation)
            return try self.readStorages(session)
        }
    }

    func list(storage: UInt32, parent: UInt32?, generation: UUID) async throws -> [GalaxyEntry] {
        try await perform {
            let session = try self.session(for: generation)
            let collected = EntryCollector()
            let result = galaxy_mtp_list(session, storage, parent ?? UInt32.max, { id, name, isFolder, size, context in
                guard let context else { return }
                let collector = Unmanaged<EntryCollector>.fromOpaque(context).takeUnretainedValue()
                let title = name.flatMap { String(validatingUTF8: $0) } ?? "항목 \(id)"
                collector.entries.append(GalaxyEntry(id: id, name: title, kind: isFolder ? .folder : .file, size: size))
            }, Unmanaged.passUnretained(collected).toOpaque())
            guard result == GALAXY_MTP_OK else { throw MTPError(result) }
            return collected.entries.sorted { left, right in
                if left.kind != right.kind { return left.kind == .folder }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }

    func download(_ entry: GalaxyEntry, to destination: URL, generation: UUID, control: TransferControl) async throws {
        try await perform {
            let session = try self.session(for: generation)
            guard !control.snapshot.cancelled else { throw MTPError.cancelled }
            let directory = destination.deletingLastPathComponent()
                .appendingPathComponent(".MacToGalaxy-\(UUID().uuidString)", isDirectory: true)
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: directory) }

            let staging = directory.appendingPathComponent("transfer")
            let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            let result = galaxy_mtp_download(session, entry.id, fd, { completed, total, context in
                guard let context else { return 1 }
                let control = Unmanaged<TransferControl>.fromOpaque(context).takeUnretainedValue()
                return control.update(completed: completed, total: total)
            }, Unmanaged.passUnretained(control).toOpaque())
            let size = lseek(fd, 0, SEEK_END)
            let closeStatus = Darwin.close(fd)
            let closeError = errno
            guard !control.snapshot.cancelled else { throw MTPError.cancelled }
            guard result == GALAXY_MTP_OK else { throw MTPError(result) }
            guard closeStatus == 0 else { throw POSIXError(POSIXErrorCode(rawValue: closeError) ?? .EIO) }
            guard size >= 0, UInt64(size) == entry.size else { throw MTPError.incompleteCopy }

            if renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                let renameError = errno
                if renameError == EEXIST { throw MTPError.destinationExists }
                throw POSIXError(POSIXErrorCode(rawValue: renameError) ?? .EIO)
            }
        }
    }

    private func session(for generation: UUID) throws -> OpaquePointer {
        guard self.generation == generation, let session else { throw MTPError.notConnected }
        return session
    }

    private func readStorages(_ session: OpaquePointer) throws -> [GalaxyEntry] {
        let collected = EntryCollector()
        let result = galaxy_mtp_storages(session, { id, name, context in
            guard let context else { return }
            let collector = Unmanaged<EntryCollector>.fromOpaque(context).takeUnretainedValue()
            let title = name.flatMap { String(validatingUTF8: $0) }
            let displayName = title.flatMap { $0.isEmpty ? nil : $0 } ?? "휴대전화 저장소"
            collector.entries.append(GalaxyEntry(id: id, name: displayName, kind: .storage))
        }, Unmanaged.passUnretained(collected).toOpaque())
        guard result == GALAXY_MTP_OK else { throw MTPError(result) }
        return collected.entries
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    private func close() {
        galaxy_mtp_close(session)
        session = nil
    }
}
