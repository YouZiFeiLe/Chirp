import ChirpMLS
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import Photos
import PhotosUI
#endif

#if os(macOS)
private struct PairingPNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw DevicePairingError.invalidQR }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif

struct NewDevicePairingView: View {
    @Bindable var setup: IdentitySetupController
    @State private var qrImage: (sessionID: UUID, png: Data)?
    #if os(macOS)
    @State private var exporting = false
    #endif
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ChirpSectionHeading(title: "使用已有设备授权")
            if let session = setup.pairing {
                if !session.stopped && !session.completed {
                    MessageText("在其他已授权设备的设置中选择授权新设备。扫描二维码后，请保持两台设备的授权页面打开。")
                        .font(.callout).foregroundStyle(ChirpTheme.secondary)
                    if let qrImage, qrImage.sessionID == session.id, let source = CGImageSourceCreateWithData(qrImage.png as CFData, nil),
                       let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                        Image(decorative: bitmap, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 300).frame(maxWidth: .infinity)
                            .accessibilityLabel(Text(verbatim: LocalizedMessage(stringLiteral: "设备授权二维码").localized(in: AppLanguage.load().locale)))
                            .accessibilityIdentifier("device-pairing-qr")
                            .accessibilityHidden(false)
                        #if os(iOS)
                        SavePairingPhotoButton(png: qrImage.png, session: session).id(session.id)
                        #else
                        Button { exporting = true } label: { MessageLabel("保存二维码为 PNG", systemImage: "square.and.arrow.down") }
                            .frame(minHeight: 44).accessibilityIdentifier("export-device-pairing-png")
                        #endif
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let count = max(0, Int(session.request.expiresAt - Int64(context.date.timeIntervalSince1970)))
                        MessageText("二维码剩余有效时间：\(count) 秒")
                            .font(.caption).foregroundStyle(ChirpTheme.secondary)
                    }
                    if session.decimals.count == 3 {
                        PairingSafetyCode(decimals: session.decimals)
                        MessageText("请直接核对旧设备显示的三组安全码。两台设备上的码完全一致后，再确认。不要通过尚未验证的通话核对。")
                            .font(.callout).foregroundStyle(ChirpTheme.secondary)
                        if session.localConfirmed {
                            MessageLabel("已确认，等待旧设备完成授权", systemImage: "hourglass")
                        } else {
                            Button { Task { await session.confirmNewDevice() } } label: { MessageText("两台设备安全码一致，确认") }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!session.canConfirm)
                                .accessibilityIdentifier("confirm-new-device-pairing-code")
                        }
                    } else { ProgressView { MessageText("等待旧设备扫描或导入二维码…") } }
                    Button(role: .cancel) { setup.stopPairing() } label: { MessageText("取消本次设备授权") }
                        .frame(minHeight: 44)
                } else if session.completed {
                    MessageLabel("双向认证已完成", systemImage: "checkmark.shield")
                    if setup.failure != nil {
                        Button { Task { await setup.completePairingLogin() } } label: { MessageText("重试完成登录") }
                            .buttonStyle(.borderedProminent).disabled(setup.busy)
                    } else { ProgressView { MessageText("正在完成新设备登录…") } }
                } else {
                    MessageText("本次授权已停止，请重新生成二维码。")
                    startButton
                }
                if let error = session.failure { Text(verbatim: error).foregroundStyle(ChirpTheme.danger).font(.callout) }
            } else {
                MessageText("使用另一台已授权设备扫描二维码，或在该设备上导入二维码图片。导入图片必须输入新设备当前显示的安全码。")
                    .font(.callout).foregroundStyle(ChirpTheme.secondary)
                startButton
            }
            if let failure { Text(verbatim: failure).font(.callout).foregroundStyle(ChirpTheme.danger) }
        }
        .chirpSurface()
        #if os(macOS)
        .fileExporter(isPresented: $exporting, document: qrImage.map { PairingPNGDocument(data: $0.png) }, contentType: .png,
                      defaultFilename: "Chirp-device-authorization.png") { result in
            if case .failure(let error) = result, (error as NSError).code != CocoaError.userCancelled.rawValue { failure = error.localizedDescription }
        }
        #endif
        .task(id: setup.pairing?.id) {
            qrImage = nil; failure = nil
            guard let session = setup.pairing else { return }
            do { qrImage = (session.id, try DevicePairingImages.png(request: session.request)) }
            catch { failure = error.localizedDescription }
            while !Task.isCancelled, setup.pairing === session, setup.step == .authorize, !session.stopped {
                await setup.pollPairing()
                if session.completed { break }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    private var startButton: some View {
        Button { Task { await setup.startPairing() } } label: {
            HStack { if setup.busy { ProgressView().controlSize(.small) }; MessageLabel("获取设备授权二维码", systemImage: "qrcode") }
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(setup.busy)
        .accessibilityIdentifier("start-device-pairing")
    }
}

#if os(iOS)
private struct SavePairingPhotoButton: View {
    let png: Data
    let session: DevicePairingSession
    private enum Status: Equatable { case idle, saving, saved, failed(LocalizedMessage) }
    @State private var status = Status.idle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { status = .saving } label: {
                MessageLabel("保存二维码到照片图库", systemImage: "square.and.arrow.down")
            }
            .frame(minHeight: 44).disabled(status == .saving)
            .accessibilityIdentifier("export-device-pairing-png")
            switch status {
            case .saved:
                MessageLabel("二维码已保存到照片图库", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(ChirpTheme.accent)
                    .accessibilityIdentifier("device-pairing-photo-saved")
            case .failed(let message):
                MessageText(message).font(.callout).foregroundStyle(ChirpTheme.danger)
                    .accessibilityIdentifier("device-pairing-photo-error")
            case .saving: ProgressView().controlSize(.small)
            case .idle: EmptyView()
            }
        }
        .task(id: status == .saving) {
            if status == .saving { await saveToPhotos() }
        }
    }

    private func saveToPhotos() async {
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard !Task.isCancelled else { return }
        guard permission == .authorized || permission == .limited else {
            status = .failed("无法添加照片。请检查系统设置中 Chirp 的照片权限。")
            return
        }
        guard session.active, session.request.expirationDate > .now else {
            status = .failed("本次授权已停止，请重新生成二维码。")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable [png] in
                let options = PHAssetResourceCreationOptions()
                options.contentType = .png
                options.originalFilename = "Chirp-device-authorization.png"
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: options)
            }
            status = .saved
        } catch {
            status = .failed("二维码保存失败，请重试。")
        }
    }
}
#endif

private struct PairingSafetyCode: View {
    let decimals: [Int]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageText("本次设备授权安全码").font(.callout.weight(.medium))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { groups }
                VStack(alignment: .leading, spacing: 12) { groups }
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("device-pairing-safety-code")
        }
    }
    private var groups: some View {
        ForEach(Array(decimals.enumerated()), id: \.offset) { _, value in
            Text(verbatim: String(format: "%04d", value)).font(.title3.monospaced().weight(.semibold))
                .padding(12).background(ChirpTheme.surfaceSubtle, in: .rect(cornerRadius: 10)).fixedSize()
        }
    }
}

enum DevicePairingSource: Hashable, Identifiable {
    case camera
    #if os(iOS)
    case photoLibrary
    #else
    case imageFile(URL)
    #endif

    var id: Self { self }
}

struct DevicePairingFlowView: View {
    @Environment(ApplicationSession.self) private var application
    @Environment(LoginSession.self) private var login
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage

    private enum Input {
        case cameraCode(String)
        #if os(iOS)
        case photo(NSItemProvider)
        #else
        case imageFile(URL)
        #endif
    }

    private enum Stage {
        case scanning
        #if os(iOS)
        case pickingPhoto
        #endif
        case checking(Input)
        case approval(DevicePairingSession)
        case failed(String)
    }

    init(source: DevicePairingSource) {
        let initial: Stage = switch source {
        case .camera: .scanning
        #if os(iOS)
        case .photoLibrary: .pickingPhoto
        #else
        case .imageFile(let url): .checking(.imageFile(url))
        #endif
        }
        _stage = State(initialValue: initial)
    }

    var body: some View {
        switch stage {
        case .scanning:
            DevicePairingCameraView { stage = .checking(.cameraCode($0)) }
        #if os(iOS)
        case .pickingPhoto:
            DevicePairingPhotoPicker { provider in
                if let provider { stage = .checking(.photo(provider)) }
                else { dismiss() }
            }
        #endif
        case .checking(let input):
            status {
                ProgressView { MessageText("正在核验设备授权请求…") }
            }
            .task { await prepare(input) }
        case .approval(let session):
            DevicePairingApprovalView(session: session)
        case .failed(let failure):
            status { Text(verbatim: failure).foregroundStyle(ChirpTheme.danger) }
        }
    }

    private func status(@ViewBuilder content: () -> some View) -> some View {
        NavigationStack {
            content()
                .font(.callout)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .messageNavigationTitle("授权新设备")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { MessageText("取消") }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 440)
        #endif
    }

    private func prepare(_ input: Input) async {
        do {
            let code: String
            let importedImage: Bool
            switch input {
            case .cameraCode(let value):
                code = value
                importedImage = false
            #if os(iOS)
            case .photo(let provider):
                code = try await DevicePairingPhotoPicker.request(from: provider).code
                importedImage = true
            #else
            case .imageFile(let url):
                let request = try await Task.detached(priority: .userInitiated) {
                    try DevicePairingImages.request(fromImage: url)
                }.value
                code = try request.code
                importedImage = true
            #endif
            }
            try Task.checkCancellation()
            guard let connection = login.session?.connection ?? login.server.connection else { throw ClientFailure(.invalidServerConfiguration) }
            let session = try await DevicePairingSession.approvingDevice(
                code: code, identity: application.identity, connection: connection, importedImage: importedImage,
                requireClock: application.networkClock.requireReady)
            if Task.isCancelled { session.stop(); return }
            stage = .approval(session)
        } catch {
            if !Task.isCancelled { stage = .failed(error.localizedDescription) }
        }
    }
}

#if os(iOS)
private struct DevicePairingPhotoPicker: UIViewControllerRepresentable {
    let onFinish: (NSItemProvider?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: (NSItemProvider?) -> Void

        init(onFinish: @escaping (NSItemProvider?) -> Void) { self.onFinish = onFinish }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onFinish(results.first?.itemProvider)
        }
    }

    static func request(from provider: NSItemProvider) async throws -> DevicePairingRequest {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            throw DevicePairingError.invalidQR
        }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, error in
                // The provider's temporary file is valid only while this callback runs.
                continuation.resume(with: Result {
                    if let error { throw error }
                    guard let url else { throw DevicePairingError.invalidQR }
                    return try DevicePairingImages.request(fromImage: url)
                })
            }
        }
    }
}

private final class PairingDigitField: UITextField {
    weak var previousField: UITextField?

    override func deleteBackward() {
        guard !hasText, let previousField else { super.deleteBackward(); return }
        previousField.becomeFirstResponder()
        let end = previousField.endOfDocument
        previousField.selectedTextRange = previousField.textRange(from: end, to: end)
        if previousField.hasText { previousField.deleteBackward() }
    }
}

@MainActor @Observable final class PairingCodeEditor: NSObject, UITextFieldDelegate {
    let fields: [UITextField]
    private(set) var focusedGroup: Int?
    private(set) var completeCode = ""

    override init() {
        let digitFields = (0..<3).map { _ in PairingDigitField() }
        fields = digitFields
        super.init()
        for (index, field) in digitFields.enumerated() {
            field.tag = index
            field.delegate = self
            if index > 0 { field.previousField = fields[index - 1] }
            field.keyboardType = .asciiCapableNumberPad
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.writingToolsBehavior = .none
            field.textAlignment = .center
            field.textColor = UIColor(ChirpTheme.ink)
            field.tintColor = UIColor(ChirpTheme.accent)
            field.defaultTextAttributes[.kern] = 2
            field.attributedPlaceholder = NSAttributedString(string: "····", attributes: [
                .foregroundColor: UIColor(ChirpTheme.secondary), .kern: 2
            ])
            field.accessibilityIdentifier = "imported-pairing-safety-code-\(index + 1)"
        }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { focusedGroup = textField.tag }
    func textFieldDidEndEditing(_ textField: UITextField) {
        if focusedGroup == textField.tag { focusedGroup = nil }
    }

    // Route the edit before switching first responder so rapid keystrokes and pastes keep their order.
    func textField(_ textField: UITextField, shouldChangeCharactersInRanges ranges: [NSValue],
                   replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        guard ranges.count == 1, let range = ranges.first.flatMap({ Range($0.rangeValue, in: current) }) else { return false }
        let digits = string.filter { $0.isASCII && $0.isNumber }
        guard string.isEmpty || !digits.isEmpty else { return false }

        let wholeCode = digits.count == 12
        let start = wholeCode ? 0 : textField.tag
        let value = wholeCode ? digits : current.replacingCharacters(in: range, with: digits)
        if value.count < 4 {
            completeCode = ""
            if digits == string { return true }
            textField.text = value
            let offset = current.distance(from: current.startIndex, to: range.lowerBound) + digits.count
            // UIKit finishes the paste transaction after the delegate returns.
            Task { @MainActor [weak textField] in
                guard let field = textField, field.isFirstResponder, field.text == value,
                      let caret = field.position(from: field.beginningOfDocument, offset: offset) else { return }
                field.selectedTextRange = field.textRange(from: caret, to: caret)
            }
            return false
        }
        let last = start + (value.count - 1) / 4
        let following = fields.dropFirst(start + 1).prefix(last - start)
        guard last < fields.count, wholeCode || following.allSatisfy({ !$0.hasText }) else { return false }

        var remaining = value[...]
        for group in start...last {
            fields[group].text = String(remaining.prefix(4))
            remaining = remaining.dropFirst(4)
        }
        let incomplete = fields.filter { ($0.text?.count ?? 0) < 4 }
        completeCode = incomplete.isEmpty ? fields.compactMap(\.text).joined() : ""
        if let next = incomplete.first(where: { $0.tag >= last }) ?? incomplete.first {
            next.becomeFirstResponder()
            let end = next.endOfDocument
            next.selectedTextRange = next.textRange(from: end, to: end)
        } else {
            textField.resignFirstResponder()
        }
        return false
    }

    func clear() {
        for field in fields { field.text = "" }
        completeCode = ""
    }
}

private struct PairingNumberInput: UIViewRepresentable {
    let field: UITextField
    let fontSize: CGFloat
    let label: LocalizedMessage

    func makeUIView(context: Context) -> UITextField { field }
    func updateUIView(_ field: UITextField, context: Context) {
        if field.font?.pointSize != fontSize {
            field.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        }
        field.accessibilityLabel = label.localized(in: context.environment.locale)
    }
}

private struct PairingCodeFields: View {
    let editor: PairingCodeEditor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var digitSize: CGFloat = 22

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            ForEach(editor.fields.indices, id: \.self) { index in
                let isFocused = editor.focusedGroup == index
                VStack(spacing: 6) {
                    MessageText("第 \(index + 1) 组")
                        .font(.caption.weight(.medium)).foregroundStyle(ChirpTheme.secondary)
                        .accessibilityHidden(true)
                    PairingNumberInput(field: editor.fields[index], fontSize: digitSize, label: "第 \(index + 1) 组安全码")
                        .frame(maxWidth: .infinity).frame(height: max(48, digitSize + 20))
                        .background(ChirpTheme.surfaceSubtle, in: .rect(cornerRadius: ChirpTheme.Radius.control))
                        .overlay {
                            RoundedRectangle(cornerRadius: ChirpTheme.Radius.control)
                                .strokeBorder(isFocused ? ChirpTheme.accent : ChirpTheme.border, lineWidth: isFocused ? 2 : 1)
                                .allowsHitTesting(false)
                        }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
#endif

private struct DevicePairingApprovalView: View {
    let session: DevicePairingSession
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var codeEditor = PairingCodeEditor()
    private var enteredCode: String { codeEditor.completeCode }
    #else
    @State private var enteredCode = ""
    #endif
    @State private var canEnroll = true
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: session.request.origin).font(.callout).textSelection(.enabled)
                    if session.active {
                        let end = session.request.expirationDate
                        LabeledContent {
                            Text(timerInterval: min(.now, end)...end, countsDown: true, showsHours: false)
                                .monospacedDigit().fixedSize()
                        } label: { MessageText("授权剩余时间") }
                        .accessibilityIdentifier("device-pairing-countdown")
                    }
                    MessageText("仅授权您本人持有的新设备。请直接查看两台设备的屏幕核对，不要批准陌生人发来的二维码。")
                        .font(.callout)
                } header: { MessageText("确认新设备授权") }
                if session.completed {
                    Section {
                        MessageLabel("设备授权已批准", systemImage: "checkmark.shield")
                        MessageText("新设备成功登录后，账号原有在线会话将自动退出。")
                    }
                } else if session.decimals.count == 3 {
                    Section {
                        if session.importedImage && !session.localConfirmed {
                            MessageText("请查看新设备当前授权页面上的三组安全码，并在这里输入全部 12 位数字。")
                            #if os(iOS)
                            PairingCodeFields(editor: codeEditor)
                            #else
                            TextField("新设备上的三组安全码", text: $enteredCode).textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("imported-pairing-safety-code")
                            #endif
                        } else {
                            PairingSafetyCode(decimals: session.decimals)
                            MessageText("请核对新设备上的三组安全码，必须完全一致。")
                        }
                        if session.localConfirmed { MessageText("已确认，等待新设备确认安全码。") }
                        else {
                            Toggle("允许新设备继续授权其他设备", isOn: $canEnroll)
                            approvalButton
                        }
                    } header: { MessageText("双向身份核验") }
                } else if !session.stopped { ProgressView { MessageText("正在建立双向身份核验…") } }
                if let failure = session.failure { Text(verbatim: failure).foregroundStyle(ChirpTheme.danger).font(.callout) }
            }
            .formStyle(.grouped).chirpForm().messageNavigationTitle("授权新设备")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { session.stop(); dismiss() } label: { MessageText(session.completed ? "完成" : "取消") }.disabled(session.isConfirming)
                }
            }
        }
        .interactiveDismissDisabled(session.isConfirming)
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 440)
        #endif
        .task {
            while !Task.isCancelled, session.active {
                await session.poll()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .task(id: session.active) {
            if session.active { await session.stopAtExpiration() }
        }
        .onDisappear { session.stop(); clearCode() }
    }

    private var approvalButton: some View {
        Button { confirming = true } label: {
            #if os(iOS)
            MessageText(session.importedImage ? "确认并发起核验" : "核对安全码并批准设备")
                .font(.headline).multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            #else
            MessageText("核对安全码并批准设备")
            #endif
        }
        .buttonStyle(.borderedProminent)
        .disabled(!session.canConfirm || (session.importedImage && enteredCode.isEmpty))
        .accessibilityIdentifier("approve-device-pairing")
        #if os(iOS)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: ChirpTheme.Radius.control))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        #endif
        .alert("批准此设备？", isPresented: $confirming) {
            Button { Task { await session.approve(enteredCode: enteredCode, canEnroll: canEnroll); clearCode() } } label: { MessageText("确认批准并验证本机身份") }
            Button(role: .cancel) {} label: { MessageText("取消") }
        } message: {
            MessageText("请确认这是您本人新设备上生成的请求，且双方安全码完全一致。批准后该设备将获得账号授权；新设备成功登录后，账号原有在线会话将自动退出。")
        }
    }

    private func clearCode() {
        #if os(iOS)
        codeEditor.clear()
        #else
        enteredCode = ""
        #endif
    }
}
