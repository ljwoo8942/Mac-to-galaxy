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
    case cannotWrite
    case invalidUploadName
    case invalidUploadSource
    case uploadSourceChanged
    case uploadUnverified
    case uploadCleanupUnverified(String)

    init(_ status: GalaxyMTPResult) {
        switch status {
        case GALAXY_MTP_UNAVAILABLE: self = .noFileTransfer
        case GALAXY_MTP_AMBIGUOUS: self = .multipleDevices
        case GALAXY_MTP_OPEN_FAILED: self = .cannotOpen
        case GALAXY_MTP_STORAGE_UNAVAILABLE: self = .noStorage
        case GALAXY_MTP_CANCELLED: self = .cancelled
        case GALAXY_MTP_WRITE_FAILED: self = .cannotWrite
        case GALAXY_MTP_UPLOAD_UNVERIFIED: self = .uploadUnverified
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
        case .cannotWrite: return "갤럭시에 파일을 쓰지 못했습니다. 저장 공간과 USB 연결을 확인하세요."
        case .invalidUploadName: return "갤럭시에서 사용할 수 있는 파일 이름으로 바꿔 주세요."
        case .invalidUploadSource: return "Mac에서 보낼 수 있는 일반 파일을 선택하세요."
        case .uploadSourceChanged: return "보내는 동안 Mac의 원본 파일이 변경되었습니다. 저장을 마친 뒤 다시 시도하세요."
        case .uploadUnverified: return "전송 완료를 확인하지 못했습니다. 갤럭시의 대상 폴더를 확인하세요."
        case let .uploadCleanupUnverified(name):
            return "임시 파일 정리를 확인하지 못했습니다. 갤럭시의 대상 폴더에서 ‘\(name)’ 파일을 확인하세요."
        }
    }
}

final class TransferControl: @unchecked Sendable {
    fileprivate static let progress: GalaxyMTPProgress = { completed, total, context in
        guard let context else { return 1 }
        let control = Unmanaged<TransferControl>.fromOpaque(context).takeUnretainedValue()
        return control.update(completed: completed, total: total)
    }

    private let lock = NSLock()
    private var cancelled = false
    private var finalizing = false
    private var fraction: Double?

    var snapshot: (cancelled: Bool, finalizing: Bool, fraction: Double?) {
        lock.lock()
        defer { lock.unlock() }
        return (cancelled, finalizing, fraction)
    }

    func cancel() {
        lock.lock()
        if !finalizing { cancelled = true }
        lock.unlock()
    }

    fileprivate func beginFinalizing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        finalizing = true
        return true
    }

    private func update(completed: UInt64, total: UInt64) -> Int32 {
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
            let session = try self.openSession(for: device)
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
            return try self.readEntries(session, storage: storage, parent: parent ?? UInt32.max).sorted { left, right in
                if left.kind != right.kind { return left.kind == .folder }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }

    func download(_ entry: GalaxyEntry, to destination: URL, generation: UUID, control: TransferControl) async throws {
        try await perform {
            let session = try self.session(for: generation)
            guard !control.snapshot.cancelled else { throw MTPError.cancelled }
            let parent = destination.deletingLastPathComponent()
            let directory = parent.appendingPathComponent(".MacToGalaxy-\(UUID().uuidString)", isDirectory: true)
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: directory) }

            let staging = directory.appendingPathComponent("transfer")
            let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            let result = galaxy_mtp_download(session, entry.id, fd, TransferControl.progress,
                                             Unmanaged.passUnretained(control).toOpaque())
            let size = lseek(fd, 0, SEEK_END)
            let closeStatus = Darwin.close(fd)
            let closeError = errno
            guard !control.snapshot.cancelled else { throw MTPError.cancelled }
            guard result == GALAXY_MTP_OK else { throw MTPError(result) }
            guard closeStatus == 0 else { throw POSIXError(POSIXErrorCode(rawValue: closeError) ?? .EIO) }
            guard size >= 0, UInt64(size) == entry.size else { throw MTPError.incompleteCopy }

            // Foundation decomposes file URL paths, even on volumes that preserve NFC names.
            let parentPath = parent.path
            let separator = parentPath.hasSuffix("/") ? "" : "/"
            let destinationPath = parentPath + separator + destination.lastPathComponent.precomposedStringWithCanonicalMapping
            if renamex_np(staging.path, destinationPath, UInt32(RENAME_EXCL)) != 0 {
                let renameError = errno
                if renameError == EEXIST { throw MTPError.destinationExists }
                throw POSIXError(POSIXErrorCode(rawValue: renameError) ?? .EIO)
            }
        }
    }

    func upload(_ source: URL, to path: [GalaxyEntry], on device: GalaxyDevice, generation: UUID,
                control: TransferControl) async throws -> UInt32 {
        try await perform {
            let session = try self.session(for: generation)
            guard let storage = path.first, storage.kind == .storage,
                  path.dropFirst().allSatisfy({ $0.kind == .folder }) else { throw MTPError.notConnected }
            guard let filename = GalaxyEntry.uploadFilename(source.lastPathComponent) else {
                throw MTPError.invalidUploadName
            }
            let fd = source.withUnsafeFileSystemRepresentation { path in
                path.map { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
            }
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = Darwin.close(fd) }

            var original = stat()
            guard fstat(fd, &original) == 0, original.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  original.st_size >= 0 else { throw MTPError.invalidUploadSource }
            let size = UInt64(original.st_size)
            let parentID = path.dropFirst().last?.id ?? UInt32.max
            let entries = try self.readEntries(session, storage: storage.id, parent: parentID)
            guard !entries.contains(where: { $0.conflictsWithUpload(named: filename) }) else {
                throw MTPError.destinationExists
            }
            guard !control.snapshot.cancelled else { throw MTPError.cancelled }

            let temporaryName = "MacToGalaxy-\(UUID().uuidString).part"
            var objectID: UInt32 = 0
            do {
                let result = galaxy_mtp_stage_upload(session, storage.id, parentID, temporaryName, size, fd, &objectID,
                                                     TransferControl.progress, Unmanaged.passUnretained(control).toOpaque())
                guard !control.snapshot.cancelled else { throw MTPError.cancelled }
                guard result == GALAXY_MTP_OK else { throw MTPError(result) }

                var current = stat()
                guard fstat(fd, &current) == 0, current.st_size == original.st_size,
                      current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
                      current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else {
                    throw MTPError.uploadSourceChanged
                }
                let latestEntries = try self.readEntries(session, storage: storage.id, parent: parentID)
                guard !latestEntries.contains(where: { $0.conflictsWithUpload(named: filename) }) else {
                    throw MTPError.destinationExists
                }
                guard control.beginFinalizing() else { throw MTPError.cancelled }
                let finish = galaxy_mtp_finish_upload(session, storage.id, parentID, objectID, size, temporaryName, filename)
                guard finish == GALAXY_MTP_OK else { throw MTPError(finish) }
                return objectID
            } catch {
                // Some phones stop answering on the original MTP session after a USB cancel.
                let cancelled = control.snapshot.cancelled
                let target = cancelled ? (try? self.reopenFolder(path, on: device)) : (session, storage.id, parentID)
                guard let (currentSession, currentStorage, currentParent) = target,
                      self.removeStagedUpload(currentSession, storage: currentStorage, parent: currentParent,
                                              objectID: cancelled ? 0 : objectID, name: temporaryName) else {
                    throw MTPError.uploadCleanupUnverified(temporaryName)
                }
                throw cancelled ? MTPError.cancelled : error
            }
        }
    }

    private func reopenFolder(_ path: [GalaxyEntry], on device: GalaxyDevice) throws -> (OpaquePointer, UInt32, UInt32) {
        close()
        guard SystemUSB.devices() == [device], let originalStorage = path.first else { throw MTPError.notConnected }
        let session = try openSession(for: device)
        do {
            guard SystemUSB.devices() == [device],
                  let storage = try readStorages(session).first(where: { $0 == originalStorage }) else {
                throw MTPError.notConnected
            }
            var parent = UInt32.max
            for component in path.dropFirst() {
                let matches = try readEntries(session, storage: storage.id, parent: parent)
                    .filter { $0.kind == .folder && $0.name == component.name }
                guard matches.count == 1, let folder = matches.first else { throw MTPError.notConnected }
                parent = folder.id
            }
            return (session, storage.id, parent)
        } catch {
            close()
            throw error
        }
    }

    private func removeStagedUpload(_ session: OpaquePointer, storage: UInt32, parent: UInt32,
                                    objectID: UInt32, name: String) -> Bool {
        guard let entries = try? readEntries(session, storage: storage, parent: parent) else { return false }
        let matches = entries.filter { $0.name == name }
        guard let entry = matches.first else { return true }
        guard matches.count == 1, entry.kind == .file,
              objectID == 0 || objectID == UInt32.max || entry.id == objectID else { return false }
        return galaxy_mtp_finish_upload(session, storage, parent, entry.id, 0, name, nil) == GALAXY_MTP_OK
    }

    private func readEntries(_ session: OpaquePointer, storage: UInt32, parent: UInt32) throws -> [GalaxyEntry] {
        let collected = EntryCollector()
        let result = galaxy_mtp_list(session, storage, parent, { id, name, isFolder, size, context in
            guard let context else { return }
            let collector = Unmanaged<EntryCollector>.fromOpaque(context).takeUnretainedValue()
            let title = name.flatMap { String(validatingUTF8: $0) } ?? "항목 \(id)"
            collector.entries.append(GalaxyEntry(id: id, name: title, kind: isFolder ? .folder : .file, size: size))
        }, Unmanaged.passUnretained(collected).toOpaque())
        guard result == GALAXY_MTP_OK else { throw MTPError(result) }
        return collected.entries
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

    private func openSession(for device: GalaxyDevice) throws -> OpaquePointer {
        var opened: OpaquePointer?
        let result = galaxy_mtp_open(GalaxyDevice.samsungVendorID, device.productID, &opened)
        guard result == GALAXY_MTP_OK, let opened else { throw MTPError(result) }
        session = opened
        return opened
    }

    private func close() {
        galaxy_mtp_close(session)
        session = nil
    }
}
