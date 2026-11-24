import ChirpMLS
import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let chirpRecovery = UTType(exportedAs: "cn.youzifeile.chirp.chirpkey", conformingTo: .data) }
struct RecoveryFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.chirpRecovery, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }; self.data = data }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private enum RecoveryFilePurpose { case restore, verify, resume }

private struct RecoveryFileSelection: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let purpose: RecoveryFilePurpose
    let token: String
}

struct IdentitySetupView: View {
    @Bindable var setup: IdentitySetupController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @FocusState private var passwordFocused: Bool
    @FocusState private var confirmationFocused: Bool
    @State private var exporting = false
    @State private var exportRecord: PendingIdentitySetup?
    @State private var exportScope = ""
    @State private var importing = false
    @State private var importPurpose = RecoveryFilePurpose.restore
    @State private var importToken = ""
    @State private var selectedFile: RecoveryFileSelection?
    @State private var unlockRequest: RecoveryFileSelection?
    @State private var confirmingGeneration = false
    @State private var passwordSubmitted = false
    @State private var fileFailure: String?
    @State private var savedFilename: String?
    @State private var remaining = 5

    static let explanation: LocalizedMessage = "此文件用于在原设备丢失或无法使用时恢复你的账号加密身份，并为新设备建立授权。恢复时必须同时提供文件和当初设置的密码，管理员无法找回根密钥或解密密码。文件与密码同时泄露，可能导致身份被冒用；没有可用恢复文件或忘记其密码，且也没有可授权设备时，将无法继续使用原加密身份。此文件不包含 Passkey 或聊天记录，也不能解除账号封禁。请确认文件已保存到你能再次找到的位置，并妥善保管密码。"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if setup.step != .authorize && setup.step != .resume { progress }
                    if setup.step == .confirmation {
                        confirmationCard
                    } else if setup.step == .authorize {
                        restoreCard
                        enrollmentCard
                    } else if setup.step == .resume {
                        resumeCard
                    } else if setup.pending == nil {
                        passwordCard
                    } else {
                        saveCard
                    }
                    if unlockRequest == nil, let failure = fileFailure ?? setup.failure {
                        RecoveryFailure(message: failure)
                    }
                    if setup.step != .confirmation { recoveryDetails }
                }
                .frame(maxWidth: 520)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("identity-setup-scroll")
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .background(ChirpTheme.canvas)
            .logScreen("identitySetup")
            .messageNavigationTitle("账号身份与恢复文件")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { setup.cancel() } label: { MessageText("取消") }
                        .disabled(setup.busy)
                        .accessibilityIdentifier("cancel-identity-setup")
                }
            }
            .alert("生成恢复文件？", isPresented: $confirmingGeneration) {
                Button { generateAndSave() } label: { MessageText("生成并保存") }
                Button(role: .cancel) {} label: { MessageText("返回检查密码") }
            } message: {
                MessageText("将使用刚才设置的密码加密账号身份，随后打开系统保存窗口。请把文件保存到你能再次找到的位置，并妥善保管密码。")
            }
        }
        .tint(ChirpTheme.accent)
        .foregroundStyle(ChirpTheme.ink)
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 640, idealHeight: 780)
        #endif
        .fileExporter(isPresented: $exporting, document: exportRecord.map { RecoveryFileDocument(data: $0.file) }, contentType: .chirpRecovery, defaultFilename: setup.filename) { result in
            defer { exportRecord = nil }
            guard exportScope == setup.scope, exportRecord?.digest == setup.pending?.digest else { return }
            switch result {
            case .success(let url):
                setup.exported(success: true, expectedScope: exportScope, expectedDigest: exportRecord?.digest)
                savedFilename = url.lastPathComponent
                fileFailure = nil
            case .failure(let error):
                if !isUserCancellation(error) { fileFailure = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.chirpRecovery, .data], allowsMultipleSelection: false, onCompletion: selectFile)
        .sheet(item: $unlockRequest) { request in
            RecoveryUnlockSheet(setup: setup, request: request, selection: $selectedFile)
        }
        .onChange(of: setup.authentication?.token) {
            selectedFile = nil; unlockRequest = nil; fileFailure = nil; savedFilename = nil
            importing = false; confirmingGeneration = false; passwordSubmitted = false
        }
        .onChange(of: scenePhase) { if setup.step == .confirmation { setup.clock.setVisible(scenePhase == .active) } }
        .onDisappear { setup.clock.setVisible(false) }
        .task(id: setup.step) {
            guard setup.step == .confirmation else { return }
            setup.clock.setVisible(scenePhase == .active)
            while !Task.isCancelled, setup.step == .confirmation {
                remaining = setup.clock.remaining()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: setup.step == .authorize ? "person.badge.key" : "key.horizontal")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(ChirpTheme.accent)
                .frame(width: 56, height: 56)
                .background(ChirpTheme.surfaceSubtle, in: .rect(cornerRadius: 18))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                MessageText(pageTitle)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                MessageText(pageSubtitle)
                    .font(.callout).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let authentication = setup.authentication {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.crop.circle").accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: authentication.username).font(.subheadline.weight(.medium))
                        Text(verbatim: authentication.origin).font(.caption).foregroundStyle(ChirpTheme.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var pageTitle: LocalizedMessage {
        switch setup.step {
        case .authorize: "授权此设备或恢复身份"
        case .resume: "继续保管你的身份"
        case .confirmation: "最后，确认妥善保管"
        default: setup.pending?.exported == true ? "恢复文件已保存" : "为账号留一份恢复文件"
        }
    }

    private var pageSubtitle: LocalizedMessage {
        switch setup.step {
        case .authorize: "使用恢复文件恢复身份，或请已有设备扫描授权二维码。"
        case .resume: "上次的进度已保留，解锁后即可继续，无需重新生成文件。"
        case .confirmation: "确认文件和密码都已妥善保存，即可完成身份设置。"
        default: "设备丢失或更换时，用这份文件和密码恢复你的加密身份。"
        }
    }

    private var progress: some View {
        let current = setup.step == .confirmation ? 2 : (setup.pending == nil ? 0 : 1)
        let status: LocalizedMessage = current == 0 ? "当前步骤：设置密码" : (current == 1 ? "当前步骤：保存文件" : "当前步骤：完成设置")
        return HStack(alignment: .top, spacing: 8) {
            progressStep("设置密码", number: 0, current: current)
            progressStep("保存文件", number: 1, current: current)
            progressStep("完成设置", number: 2, current: current)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: status.localized(in: locale)))
    }

    private func progressStep(_ title: LocalizedMessage, number: Int, current: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Group {
                if number < current { Image(systemName: "checkmark") }
                else { Text(verbatim: "\(number + 1)") }
            }
            .font(.caption.weight(.semibold))
            .frame(width: 24, height: 24)
            .foregroundStyle(number <= current ? ChirpTheme.onAccent : ChirpTheme.secondary)
            .background(number <= current ? ChirpTheme.accent : ChirpTheme.surfaceSubtle, in: .circle)
            .accessibilityHidden(true)
            MessageText(title).font(.caption.weight(number == current ? .semibold : .regular))
                .foregroundStyle(number <= current ? ChirpTheme.ink : ChirpTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            ChirpSectionHeading(title: "设置文件密码")
            MessageText("这不是登录密码。请使用密码管理器生成并保管随机长密码，至少 16 个字符。")
                .font(.callout).foregroundStyle(ChirpTheme.secondary)
            RecoveryPasswordField(title: "恢复文件密码", text: $setup.password, focus: $passwordFocused, isNewPassword: true,
                                  invalid: passwordSubmitted && !passwordLengthValid)
                .onSubmit { confirmationFocused = true }
                .submitLabel(.next)
                .accessibilityIdentifier("recovery-new-password")
            if !setup.password.isEmpty || passwordSubmitted {
                passwordHint(passwordLengthValid ? "密码长度符合要求" : "至少 16 个字符，最多 1024 字节", valid: passwordLengthValid)
            }
            RecoveryPasswordField(title: "确认文件密码", text: $setup.confirmation, focus: $confirmationFocused, isNewPassword: true,
                                  invalid: passwordSubmitted && !passwordsMatch)
                .onSubmit { confirmGeneration() }
                .submitLabel(.done)
                .accessibilityIdentifier("recovery-confirm-password")
            if !setup.confirmation.isEmpty || passwordSubmitted {
                passwordHint(passwordsMatch ? "两次密码一致" : "两次输入的密码需要完全相同", valid: passwordsMatch)
            }
            primaryButton("继续", systemImage: "arrow.right", busy: setup.busy, action: confirmGeneration)
                .accessibilityIdentifier("prepare-recovery-file")
        }
        .disabled(setup.busy)
        .chirpSurface()
    }

    private var passwordLengthValid: Bool {
        setup.password.unicodeScalars.count >= 16 && setup.password.utf8.count <= 1024
    }
    private var passwordsMatch: Bool {
        !setup.confirmation.isEmpty && Array(setup.password.utf8) == Array(setup.confirmation.utf8)
    }

    private func passwordHint(_ title: LocalizedMessage, valid: Bool) -> some View {
        MessageLabel(title, systemImage: valid ? "checkmark.circle" : "info.circle")
            .font(.caption).foregroundStyle(valid ? ChirpTheme.accent : ChirpTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var saveCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            if setup.pending?.exported == true {
                MessageLabel("已完成系统保存", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(ChirpTheme.accent)
                if selectedFile?.purpose != .verify { fileSummary(name: savedFilename ?? setup.filename) }
                MessageText("建议重新选择刚才保存的文件，确认它可以用密码解锁。你也可以直接继续。")
                    .font(.callout).foregroundStyle(ChirpTheme.secondary)
                if let selectedFile, selectedFile.purpose == .verify {
                    selectedFileCard(selectedFile)
                } else {
                    Button { chooseFile(for: .verify) } label: {
                        MessageLabel(setup.backupVerified ? "再次选择文件校验" : "选择已保存的文件校验", systemImage: "doc.badge.checkmark")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("select-backup-to-verify")
                }
                if setup.backupVerified {
                    MessageLabel("校验成功，文件可以解密", systemImage: "checkmark.shield")
                        .font(.callout).foregroundStyle(ChirpTheme.accent)
                        .accessibilityIdentifier("recovery-backup-verified")
                }
                primaryButton("继续完成设置", systemImage: "arrow.right") { setup.showConfirmation() }
                    .accessibilityIdentifier("continue-after-recovery-save")
                Button { startExport() } label: { MessageText("另存一份文件") }
                    .frame(minHeight: 44)
            } else {
                ChirpSectionHeading(title: "保存恢复文件")
                fileSummary(name: setup.filename)
                MessageText("加密文件已准备好。选择一个安全的位置保存，之后再校验文件。")
                    .font(.callout).foregroundStyle(ChirpTheme.secondary)
                primaryButton("保存恢复文件", systemImage: "square.and.arrow.down", action: startExport)
                    .accessibilityIdentifier("export-recovery-file")
            }
        }
        .disabled(setup.busy)
        .chirpSurface()
    }

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            ChirpSectionHeading(title: "使用恢复文件")
            if let selectedFile, selectedFile.purpose == .restore {
                selectedFileCard(selectedFile)
            } else {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(ChirpTheme.accent).accessibilityHidden(true)
                    .frame(maxWidth: .infinity).padding(.top, 8)
                MessageText("选择你为此账号保存的恢复文件。文件确认后，再输入它的密码。")
                    .font(.callout).foregroundStyle(ChirpTheme.secondary)
                primaryButton("选择恢复文件", systemImage: "folder") { chooseFile(for: .restore) }
                    .accessibilityIdentifier("select-recovery-file")
            }
        }
        .disabled(setup.busy)
        .chirpSurface()
    }

    private func selectedFileCard(_ file: RecoveryFileSelection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            fileSummary(name: file.name)
            MessageText("请确认这是你要使用的文件，下一步输入文件密码。")
                .font(.callout).foregroundStyle(ChirpTheme.secondary)
            primaryButton(file.purpose == .verify ? "确认文件，开始校验" : "使用此文件", systemImage: "arrow.right") {
                guard file.token == setup.authentication?.token else { return }
                fileFailure = nil; unlockRequest = file
            }
            .accessibilityIdentifier("confirm-selected-recovery-file")
            Button { chooseFile(for: file.purpose) } label: { MessageText("重新选择文件") }
                .frame(minHeight: 44)
                .accessibilityIdentifier("reselect-recovery-file")
        }
    }

    private func fileSummary(name: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.zipper").font(.title2).foregroundStyle(ChirpTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name).font(.callout.weight(.medium)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recovery-selected-filename")
                MessageText("密码加密的账号恢复文件").font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ChirpTheme.canvas, in: .rect(cornerRadius: ChirpTheme.Radius.control))
    }

    private var enrollmentCard: some View { NewDevicePairingView(setup: setup) }

    private var resumeCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            ChirpSectionHeading(title: "发现未完成的设置")
            fileSummary(name: setup.filename)
            MessageText("输入上次设置的文件密码，继续保存同一份恢复文件。")
                .font(.callout).foregroundStyle(ChirpTheme.secondary)
            primaryButton("解锁并继续", systemImage: "lock.open") {
                guard let token = setup.authentication?.token, let pending = setup.pending else { return }
                unlockRequest = RecoveryFileSelection(name: setup.filename, data: pending.file, purpose: .resume, token: token)
            }
        }
        .disabled(setup.busy)
        .chirpSurface()
    }

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            MessageLabel("请再次确认恢复文件已保存", systemImage: "checkmark.shield")
                .font(.headline).foregroundStyle(ChirpTheme.accent)
            MessageText(Self.explanation).font(.callout).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if remaining > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "clock").accessibilityHidden(true)
                    MessageText("请阅读以上说明")
                    Text(verbatim: "\(remaining) s").monospacedDigit()
                }
                .font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
            primaryButton("确认已保存，完成设置", systemImage: "checkmark", busy: setup.busy) {
                Task { await setup.confirmBackup() }
            }
            .disabled(remaining > 0 || setup.busy)
            .accessibilityIdentifier("confirm-recovery-backup")
            Button { setup.backToSave() } label: { MessageText("返回检查文件") }
                .frame(minHeight: 44).disabled(setup.busy)
                .accessibilityIdentifier("save-recovery-again")
        }
        .chirpSurface()
    }

    private var recoveryDetails: some View {
        DisclosureGroup {
            MessageText(Self.explanation).font(.callout).foregroundStyle(ChirpTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
        } label: {
            MessageLabel("关于恢复文件与密码", systemImage: "info.circle")
                .font(.callout).foregroundStyle(ChirpTheme.secondary)
        }
    }

    private func primaryButton(_ title: LocalizedMessage, systemImage: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                MessageLabel(title, systemImage: systemImage)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            #if os(iOS)
            .foregroundStyle(ChirpTheme.onAccent)
            #endif
            .modifier(ChirpProminentLabelStyle())
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(busy)
    }

    private func confirmGeneration() {
        guard !setup.busy else { return }
        passwordSubmitted = true
        guard passwordLengthValid else { passwordFocused = true; return }
        guard passwordsMatch else { confirmationFocused = true; return }
        passwordFocused = false; confirmationFocused = false; confirmingGeneration = true
    }

    private func generateAndSave() {
        let token = setup.authentication?.token
        Task {
            await setup.saveEncryptedFile()
            guard setup.authentication?.token == token, setup.pending != nil, setup.failure == nil else { return }
            startExport()
        }
    }

    private func startExport() {
        ClientLog.shared.record(.identity, "exportRecoveryFile")
        guard !setup.busy, let record = setup.pending else { return }
        fileFailure = nil; exportRecord = record; exportScope = setup.scope; exporting = true
    }

    private func chooseFile(for purpose: RecoveryFilePurpose) {
        ClientLog.shared.record(.identity, "chooseRecoveryFile")
        guard !setup.busy, let token = setup.authentication?.token else { return }
        fileFailure = nil; importPurpose = purpose; importToken = token; importing = true
    }

    private func selectFile(_ result: Result<[URL], Error>) {
        guard importToken == setup.authentication?.token else { return }
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size <= 54 + 65536 + 16 else { throw IdentitySetupError.invalid("恢复文件过大。") }
            let data = try Data(contentsOf: url)
            guard !data.isEmpty, data.count <= 54 + 65536 + 16 else { throw CocoaError(.fileReadCorruptFile) }
            selectedFile = RecoveryFileSelection(name: url.lastPathComponent, data: data, purpose: importPurpose, token: importToken)
            fileFailure = nil
        } catch {
            if !isUserCancellation(error) { fileFailure = error.localizedDescription }
        }
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue
    }
}

private struct RecoveryPasswordField: View {
    let title: LocalizedMessage
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var isNewPassword = false
    var invalid = false
    @Environment(\.locale) private var locale
    @State private var visible = false

    private var visibilityLabel: LocalizedMessage { visible ? "隐藏密码" : "显示密码" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageText(title).font(.callout.weight(.medium))
            HStack(spacing: 8) {
                Group {
                    if visible { TextField(title.localized(in: locale), text: $text) }
                    else { SecureField(title.localized(in: locale), text: $text) }
                }
                .textFieldStyle(.plain)
                .textContentType(isNewPassword ? .newPassword : .password)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused(focus)
                .accessibilityLabel(Text(verbatim: title.localized(in: locale)))
                Button {
                    visible.toggle(); focus.wrappedValue = true
                } label: {
                    Image(systemName: visible ? "eye.slash" : "eye")
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ChirpTheme.secondary)
                .accessibilityLabel(Text(verbatim: visibilityLabel.localized(in: locale)))
            }
            .padding(.leading, 14).padding(.trailing, 4)
            .background(ChirpTheme.canvas, in: .rect(cornerRadius: ChirpTheme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: ChirpTheme.Radius.control)
                    .strokeBorder(invalid ? ChirpTheme.danger : (focus.wrappedValue ? ChirpTheme.accent : ChirpTheme.secondary.opacity(0.65)), lineWidth: focus.wrappedValue || invalid ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct RecoveryFailure: View {
    let message: String
    var body: some View {
        Label { Text(verbatim: message).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle") }
            .font(.callout).foregroundStyle(ChirpTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("recovery-file-error")
    }
}

private struct RecoveryUnlockSheet: View {
    let setup: IdentitySetupController
    let request: RecoveryFileSelection
    @Binding var selection: RecoveryFileSelection?
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "lock.open")
                        .font(.title).foregroundStyle(ChirpTheme.accent).accessibilityHidden(true)
                    MessageText(request.purpose == .verify ? "校验这份恢复文件" : "解锁恢复文件")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: request.name).font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    MessageText("请输入创建此文件时设置的密码。密码只在本机用于解密。")
                        .font(.callout).foregroundStyle(ChirpTheme.secondary)
                    RecoveryPasswordField(title: "恢复文件密码", text: $password, focus: $focused, invalid: failure != nil)
                        .onSubmit(unlock)
                        .submitLabel(.done)
                        .accessibilityIdentifier("recovery-unlock-password")
                    if let failure { RecoveryFailure(message: failure) }
                    Button(action: unlock) {
                        HStack(spacing: 10) {
                            if setup.busy { ProgressView().controlSize(.small) }
                            MessageText(request.purpose == .verify ? "确认并校验" : "确认并解锁")
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                        #if os(iOS)
                        .foregroundStyle(ChirpTheme.onAccent)
                        #endif
                        .modifier(ChirpProminentLabelStyle())
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(password.isEmpty || setup.busy)
                    .accessibilityIdentifier("confirm-recovery-password")
                }
                .padding(24)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .background(ChirpTheme.surface)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { MessageText("取消") }.disabled(setup.busy)
                }
            }
            .disabled(setup.busy)
        }
        .foregroundStyle(ChirpTheme.ink).tint(ChirpTheme.accent)
        .interactiveDismissDisabled(setup.busy)
        #if os(macOS)
        .frame(width: 460, height: 400)
        #endif
        .task { focused = true }
        .onChange(of: password) { if !password.isEmpty { failure = nil } }
        .onDisappear { password = ""; setup.password = "" }
    }

    private func unlock() {
        guard !password.isEmpty, !setup.busy, request.token == setup.authentication?.token else { return }
        failure = nil; setup.password = password
        Task {
            switch request.purpose {
            case .restore: await setup.importRecovery(request.data)
            case .verify: await setup.verifyBackup(request.data)
            case .resume: await setup.resume()
            }
            password = ""
            if let error = setup.failure { failure = error; focused = true }
            else {
                if request.purpose == .verify { selection = nil }
                dismiss()
            }
        }
    }
}

#if DEBUG
struct IdentitySetupPreview: View {
    var step: IdentitySetupController.Step = .password
    var saved = false
    @State private var setup: IdentitySetupController?
    @State private var failure: String?

    var body: some View {
        Group {
            if let setup { IdentitySetupView(setup: setup) }
            else if let failure { RecoveryFailure(message: failure).padding(24) }
            else { ProgressView() }
        }
        .task {
            guard setup == nil else { return }
            do { setup = try await .designPreview(step: step, saved: saved) }
            catch { failure = error.localizedDescription }
        }
    }
}

#Preview("Recovery · Create") { IdentitySetupPreview() }
#Preview("Recovery · Import") { IdentitySetupPreview(step: .authorize) }
#Preview("Recovery · Saved") { IdentitySetupPreview(saved: true).preferredColorScheme(.dark) }
#endif
