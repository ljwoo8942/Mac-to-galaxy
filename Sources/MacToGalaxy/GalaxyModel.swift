import AppKit
import Foundation
import GalaxyCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class GalaxyModel: ObservableObject {
    enum FileStatus {
        case disconnected
        case multipleDevices
        case opening
        case unavailable(String)
        case ready
    }

    enum CheckStatus {
        case idle
        case checking
        case passed(Date)
        case failed(USBInternetCheck.Outcome)
    }

    struct Transfer {
        let name: String
        let control: TransferControl
    }

    @Published private(set) var device: GalaxyDevice?
    @Published private(set) var fileStatus: FileStatus = .disconnected
    @Published private(set) var tethering: TetheringState = .noDevice
    @Published private(set) var primaryNetworkInterfaces: [String: String] = [:]
    @Published private(set) var internetCheck: CheckStatus = .idle
    @Published private(set) var entries: [GalaxyEntry] = []
    @Published private(set) var folderPath: [GalaxyEntry] = []
    @Published private(set) var loadingFolder = false
    @Published private(set) var transfer: Transfer?
    @Published private(set) var isUpdating = false
    @Published var selection: UInt32?
    @Published var previewURL: URL?
    @Published var alertMessage: String?

    private let mtp = MTPClient()
    private var generation = UUID()
    private var nextConnectionAttempt: ContinuousClock.Instant?
    private var probe: USBInternetCheck?
    private var probeID: UUID?
    private var choosingDestination = false

    var selectedEntry: GalaxyEntry? { entries.first { $0.id == selection } }
    var canBrowse: Bool {
        guard case .ready = fileStatus else { return false }
        return !loadingFolder && transfer == nil && !isUpdating
    }
    var canPreview: Bool {
        guard let selectedEntry else { return false }
        return supportsPreview(selectedEntry)
    }
    var canUpdate: Bool {
        !isUpdating && !loadingFolder && transfer == nil && !choosingDestination && previewURL == nil
    }

    func monitor() async {
        while !Task.isCancelled {
            refreshDevices()
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    func refreshFiles() {
        guard transfer == nil, !loadingFolder, !isUpdating else { return }
        nextConnectionAttempt = nil
        refreshDevices()
        if canBrowse {
            load(folderPath)
        }
    }

    func activate(_ entry: GalaxyEntry) {
        guard canBrowse, entries.contains(entry) else { return }
        if entry.kind == .file {
            if supportsPreview(entry) {
                preview(entry)
            } else {
                save(entry)
            }
        } else {
            load(folderPath + [entry])
        }
    }

    func goBack() {
        guard canBrowse, !folderPath.isEmpty else { return }
        load(Array(folderPath.dropLast()))
    }

    func previewSelected() {
        guard let selectedEntry, supportsPreview(selectedEntry) else { return }
        preview(selectedEntry)
    }

    func saveSelected() {
        guard let selectedEntry, selectedEntry.kind == .file else { return }
        save(selectedEntry)
    }

    func cancelTransfer() {
        transfer?.control.cancel()
    }

    func removePreview(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func checkInternet() {
        refreshDevices()
        guard case let .addressed(interface) = tethering, probe == nil else { return }
        internetCheck = .checking
        let id = UUID()
        probeID = id
        let check = USBInternetCheck(interfaceName: interface.name) { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDevices()
                guard self.probeID == id else { return }
                self.probe = nil
                self.probeID = nil
                switch outcome {
                case .passed: self.internetCheck = .passed(Date())
                default: self.internetCheck = .failed(outcome)
                }
            }
        }
        probe = check
        check.start()
    }

    func openNetworkSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    func updateApp() {
        guard canUpdate else { return }
        isUpdating = true
        let app = Bundle.main.bundleURL
        let revision = Bundle.main.object(forInfoDictionaryKey: AppUpdater.revisionKey) as? String
        Task {
            defer { isUpdating = false }
            do {
                guard let update = try await Task.detached(priority: .userInitiated, operation: {
                    try AppUpdater.prepare(appAt: app, runningRevision: revision)
                }).value else {
                    alertMessage = "이미 GitHub의 최신 버전입니다."
                    return
                }
                try await relaunch(with: update)
                NSApplication.shared.terminate(nil)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func relaunch(with update: PreparedAppUpdate) async throws {
        var keepBackup = false
        defer { if !keepBackup { update.discardReplacement() } }
        try update.exchangeBundles()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: update.app, configuration: configuration)
        } catch {
            do {
                try update.exchangeBundles()
            } catch {
                keepBackup = true
                throw AppUpdateError("새 앱을 열지 못했습니다. 기존 앱은 다음 위치에 있습니다.\n\(update.replacement.path)")
            }
            throw AppUpdateError("새 앱을 열지 못해 기존 버전으로 복구했습니다.")
        }
    }

    private func refreshDevices() {
        let devices = SystemUSB.devices()
        let connected = devices.count == 1 ? devices.first : nil
        let interfaces = connected.map(SystemUSB.networkInterfaces) ?? []
        let network = TetheringState(devices: devices, interfaces: interfaces)
        let primaryInterfaces = interfaces.isEmpty && (connected?.networkModes.isEmpty ?? true)
            ? [:] : SystemUSB.primaryNetworkInterfaces()
        if primaryInterfaces != primaryNetworkInterfaces {
            primaryNetworkInterfaces = primaryInterfaces
        }
        let deviceChanged = connected?.registryID != device?.registryID || connected?.productID != device?.productID
        let usbConfigurationChanged = deviceChanged || connected?.interfaceIDs != device?.interfaceIDs

        if usbConfigurationChanged || network != tethering {
            probe?.cancel()
            probe = nil
            probeID = nil
            internetCheck = .idle
            tethering = network
        }
        if connected != device { device = connected }

        if usbConfigurationChanged {
            resetFiles()
            fileStatus = connected == nil ? .disconnected : .unavailable("갤럭시의 파일 연결을 확인하는 중입니다.")
        }
        if let connected {
            connectIfNeeded(connected)
        } else if devices.count > 1 {
            if case .multipleDevices = fileStatus { return }
            fileStatus = .multipleDevices
        } else {
            if case .disconnected = fileStatus { return }
            fileStatus = .disconnected
        }
    }

    private func resetFiles() {
        transfer?.control.cancel()
        generation = UUID()
        mtp.reset(to: generation)
        entries = []
        selection = nil
        folderPath = []
        loadingFolder = false
        nextConnectionAttempt = nil
    }

    private func connectIfNeeded(_ device: GalaxyDevice) {
        guard case .unavailable = fileStatus, transfer == nil,
              nextConnectionAttempt.map({ $0 <= ContinuousClock.now }) ?? true else { return }
        fileStatus = .opening
        let generation = generation
        Task {
            do {
                let storages = try await mtp.connect(to: device, generation: generation)
                guard self.generation == generation else { return }
                entries = storages
                fileStatus = .ready
            } catch {
                guard self.generation == generation else { return }
                nextConnectionAttempt = ContinuousClock.now + .seconds(8)
                fileStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    private func load(_ path: [GalaxyEntry]) {
        loadingFolder = true
        let generation = generation
        Task {
            do {
                let contents: [GalaxyEntry]
                if let storage = path.first {
                    let parent = path.count > 1 ? path.last?.id : nil
                    contents = try await mtp.list(storage: storage.id, parent: parent, generation: generation)
                } else {
                    contents = try await mtp.storages(generation: generation)
                }
                guard self.generation == generation else { return }
                selection = nil
                folderPath = path
                entries = contents
                loadingFolder = false
            } catch {
                guard self.generation == generation else { return }
                resetFiles()
                fileStatus = .unavailable(error.localizedDescription)
                nextConnectionAttempt = ContinuousClock.now + .seconds(8)
            }
        }
    }

    private func supportsPreview(_ entry: GalaxyEntry) -> Bool {
        guard entry.kind == .file,
              let type = UTType(filenameExtension: (entry.localFilename as NSString).pathExtension) else { return false }
        return [UTType.image, .movie, .audio, .pdf, .plainText].contains { type.conforms(to: $0) }
    }

    private func preview(_ entry: GalaxyEntry) {
        guard canBrowse, !choosingDestination else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacToGalaxy-Preview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            startTransfer(entry, to: folder.appendingPathComponent(entry.localFilename), isPreview: true)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func save(_ entry: GalaxyEntry) {
        guard canBrowse, !choosingDestination else { return }
        let generation = generation
        choosingDestination = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.localFilename
        panel.canCreateDirectories = true
        panel.prompt = "저장"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.choosingDestination = false
                guard response == .OK, let url = panel.url, self.generation == generation, self.canBrowse else { return }
                self.startTransfer(entry, to: url, isPreview: false)
            }
        }
    }

    private func startTransfer(_ entry: GalaxyEntry, to url: URL, isPreview: Bool) {
        let control = TransferControl()
        let generation = generation
        transfer = Transfer(name: entry.name, control: control)
        Task {
            defer {
                transfer = nil
                if isPreview && previewURL != url {
                    removePreview(url)
                }
            }
            do {
                try await mtp.download(entry, to: url, generation: generation, control: control)
                guard self.generation == generation else { return }
                if isPreview { previewURL = url }
            } catch {
                guard self.generation == generation, !control.snapshot.cancelled else { return }
                alertMessage = error.localizedDescription
            }
        }
    }
}
