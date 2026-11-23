import AppKit
import GalaxyCore
import QuickLook
import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var model: GalaxyModel
    private let accent = Color(red: 0.09, green: 0.53, blue: 0.47)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 238)
            Divider()
            browser
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(accent)
        .quickLookPreview($model.previewURL)
        .onChange(of: model.previewURL) { old, new in
            if let old, old != new { model.removePreview(old) }
        }
        .alert("Mac-to-galaxy", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.device?.name ?? "갤럭시")
                            .font(.headline)
                            .lineLimit(2)
                        statusText(deviceStatus, active: model.device != nil)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Label("USB 테더링", systemImage: "network")
                        .font(.headline)
                    tetheringDetails
                    Button("네트워크 설정", action: model.openNetworkSettings)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Button(action: model.updateApp) {
                        Label("앱 업데이트", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.canUpdate)
                    .help("GitHub의 최신 버전을 확인하고 설치합니다.")
                    if model.isUpdating {
                        ProgressView("업데이트 준비 중…")
                            .controlSize(.small)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var deviceStatus: String {
        if case .selectOneDevice = model.tethering { return "여러 기기 연결됨" }
        return model.device == nil ? "USB 연결 대기" : "USB 연결됨"
    }

    @ViewBuilder
    private var tetheringDetails: some View {
        switch model.tethering {
        case .noDevice:
            description("갤럭시를 데이터 전송용 USB 케이블로 연결하세요.")
        case .selectOneDevice:
            description("갤럭시 한 대만 연결하세요.")
        case .waitingForTethering:
            description("갤럭시에서 설정 → 연결 → 모바일 핫스팟 및 테더링 → USB 테더링을 켜세요.")
        case let .noNetworkInterface(modes):
            let names = modes.map(\.rawValue).sorted().joined(separator: ", ")
            statusText("\(names) 감지됨", active: false)
            description("macOS 네트워크 인터페이스를 찾지 못했습니다. 네트워크 설정에서 USB 연결을 확인하세요.")
        case let .waitingForAddress(interface):
            statusText("IP 주소 대기 · \(interface.name)", active: false)
            description("네트워크 설정에서 USB 연결과 DHCP 상태를 확인하세요.")
        case let .addressed(interface):
            statusText("IP 할당됨 · \(interface.name)", active: true)
            internetCheckDetails
            Button("USB 인터넷 확인", action: model.checkInternet)
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)
                .help("USB 인터페이스를 사용해 Google 연결 확인 주소에 요청을 보냅니다.")
        }
    }

    private var isChecking: Bool {
        if case .checking = model.internetCheck { return true }
        return false
    }

    @ViewBuilder
    private var internetCheckDetails: some View {
        switch model.internetCheck {
        case .idle:
            description("USB 경로로 인터넷에 접속할 수 있는지 확인하세요.")
        case .checking:
            description("USB 경로를 확인하는 중입니다.")
        case let .passed(date):
            description("USB 인터넷 확인됨 · \(date.formatted(date: .omitted, time: .shortened))")
        case let .failed(outcome):
            switch outcome {
            case .noPath:
                description("이 USB 인터페이스의 네트워크 경로를 찾지 못했습니다.")
            case .unexpectedResponse:
                description("연결 확인 서버에서 예상과 다른 응답을 받았습니다.")
            case .failed:
                description("USB 경로에서 인터넷에 연결하지 못했습니다. 갤럭시의 모바일 데이터와 테더링 상태를 확인하세요.")
            case .passed:
                EmptyView()
            }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canBrowse || model.folderPath.isEmpty)
                .help("상위 폴더")
                .accessibilityLabel("상위 폴더")

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.folderPath.last?.name ?? "파일")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    if !model.folderPath.isEmpty {
                        Text((["저장소"] + model.folderPath.map(\.name)).joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 12)
                browserActions
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            Divider()

            fileContents
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let transfer = model.transfer {
                Divider()
                transferBar(transfer)
            }
        }
    }

    @ViewBuilder
    private var browserActions: some View {
        if let entry = model.selectedEntry, entry.kind != .file {
            Button("열기") { model.activate(entry) }
                .disabled(!model.canBrowse)
        } else {
            Button("미리보기", action: model.previewSelected)
                .disabled(!model.canBrowse || !model.canPreview)
                .help("선택한 파일 미리보기 · 스페이스바")
            Button("Mac에 저장", action: model.saveSelected)
                .disabled(!model.canBrowse || model.selectedEntry?.kind != .file)
        }
        Button(action: model.refreshFiles) {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(model.device == nil || model.loadingFolder || model.transfer != nil || model.isUpdating)
        .help("파일 새로고침")
        .accessibilityLabel("파일 새로고침")
    }

    @ViewBuilder
    private var fileContents: some View {
        switch model.fileStatus {
        case .disconnected:
            emptyState("갤럭시 연결", icon: "cable.connector", text: "USB 케이블을 연결한 뒤 갤럭시에서 ‘파일 전송’을 선택하세요.")
        case .multipleDevices:
            emptyState("여러 기기가 연결됨", icon: "iphone", text: "파일을 탐색할 갤럭시 한 대만 연결하세요.")
        case .opening:
            ProgressView("갤럭시 저장소 확인 중")
        case let .unavailable(message):
            emptyState("파일 연결 대기", icon: "folder", text: message)
        case .ready:
            if model.loadingFolder {
                ProgressView("파일을 불러오는 중")
            } else if model.entries.isEmpty {
                emptyState("빈 폴더", icon: "folder", text: "이 폴더에 표시할 파일이 없습니다.")
            } else {
                fileList
            }
        }
    }

    private var fileList: some View {
        List(model.entries, selection: $model.selection) { entry in
            HStack(spacing: 10) {
                Image(systemName: icon(for: entry.kind))
                    .frame(width: 18)
                    .foregroundStyle(entry.kind == .file ? Color.secondary : accent)
                    .accessibilityHidden(true)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if entry.kind == .file {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .tag(entry.id)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: GalaxyEntry.ID.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            guard let id = ids.first, let entry = model.entries.first(where: { $0.id == id }) else { return }
            model.activate(entry)
        }
        .onKeyPress(.space, phases: .down) { press in
            guard press.modifiers.isEmpty, model.canBrowse, model.canPreview, model.previewURL == nil else {
                return .ignored
            }
            model.previewSelected()
            return .handled
        }
        .onKeyPress(.return) {
            guard let entry = model.selectedEntry, model.canBrowse else { return .ignored }
            model.activate(entry)
            return .handled
        }
    }

    private func transferBar(_ transfer: GalaxyModel.Transfer) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let snapshot = transfer.control.snapshot
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.cancelled ? "전송 취소 중" : transfer.name)
                        .font(.caption)
                        .lineLimit(1)
                    if let fraction = snapshot.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                Spacer()
                Button("취소", action: model.cancelTransfer)
                    .disabled(snapshot.cancelled)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    private func emptyState(_ title: String, icon: String, text: String) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(text))
    }

    private func statusText(_ title: String, active: Bool) -> some View {
        Label {
            Text(title).font(.caption.weight(.medium))
        } icon: {
            Circle()
                .fill(active ? accent : Color.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func icon(for kind: GalaxyEntry.Kind) -> String {
        switch kind {
        case .storage: return "externaldrive"
        case .folder: return "folder"
        case .file: return "doc"
        }
    }
}
