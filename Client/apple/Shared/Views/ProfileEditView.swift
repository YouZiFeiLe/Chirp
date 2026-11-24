import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct SelectedAvatar: Transferable {
    let data: Data
    let image: CGImage

    init(file: URL) throws {
        let data = try AvatarImage.prepare(AvatarImage.read(file))
        guard let image = AvatarImage.decoded(data) else { throw ClientFailure(.avatarInvalid) }
        self.data = data
        self.image = image
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { try SelectedAvatar(file: $0.file) }
    }
}

enum ProfileChange {
    case nickname(String)
    case replaceAvatar(Data)
    case removeAvatar
}

struct ProfileEditView: View {
    @Environment(LoginSession.self) private var login

    var body: some View {
        if let session = login.session {
            let id = session.member.id
            ProfileEditor(memberID: id, savedName: login.profiles.displayName(for: id, fallback: session.member.displayName),
                          savedAvatar: login.profiles.image(for: id), hasAvatar: login.profiles.members[id]?.avatarRevision != nil,
                          syncMessage: login.profiles.syncMessage) { change in
                guard login.session?.credential == session.credential else { throw CancellationError() }
                do {
                    switch change {
                    case .nickname(let value): try await login.profiles.rename(value)
                    case .replaceAvatar(let data): try await login.profiles.setAvatar(data)
                    case .removeAvatar: try await login.profiles.deleteAvatar()
                    }
                } catch let error as APIError {
                    guard login.session?.credential == session.credential else { throw CancellationError() }
                    switch error {
                    case .unauthorized, .disabled:
                        login.clear(error.clientFailure)
                        throw CancellationError()
                    default: throw error
                    }
                }
            }
            .id(session.credential)
        }
    }
}

struct ProfileEditor: View {
    let memberID: String
    let savedName: String
    let savedAvatar: CGImage?
    let hasAvatar: Bool
    var syncMessage: LocalizedMessage?
    let apply: @MainActor (ProfileChange) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var editingName: Bool
    @State private var editedName: String?
    @State private var avatarDraft = AvatarDraft.original
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var confirmsDiscard = false
    @State private var isPreparing = false
    @State private var isSaving = false
    @State private var avatarError: ClientFailure?
    @State private var saveError: ClientFailure?
    @State private var nicknameAlreadySaved = false
    @State private var work: Task<Void, Never>?

    private enum AvatarDraft {
        case original, replacement(SelectedAvatar), removal

        var isChanged: Bool {
            if case .original = self { return false }
            return true
        }
    }

    private var name: String { editedName ?? savedName }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var previewName: String { trimmedName.isEmpty ? savedName : trimmedName }
    private var count: Int { trimmedName.unicodeScalars.count }
    private var nameChanged: Bool { editedName != nil && trimmedName != savedName }
    private var hasChanges: Bool { nameChanged || avatarDraft.isChanged }
    private var nameError: LocalizedMessage? {
        if trimmedName.isEmpty { return "请输入昵称。" }
        if count > VoiceRooms.maxNameLength { return "昵称超过了 80 个字符，请缩短后保存。" }
        if !VoiceRooms.validName(trimmedName) { return "昵称不能包含换行或控制字符。" }
        return nil
    }
    private var canSave: Bool { hasChanges && nameError == nil && !isPreparing && !isSaving }

    var body: some View {
        Group {
            #if os(macOS)
            VStack(alignment: .leading, spacing: 0) {
                MessageText("编辑个人资料")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 28).padding(.top, 24)
                content
                Divider()
                HStack(spacing: 12) {
                    Spacer()
                    cancelButton.keyboardShortcut(.cancelAction)
                    saveButton.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
                .controlSize(.large).padding(.horizontal, 28).padding(.vertical, 14)
            }
            .frame(width: 472, height: 480)
            #else
            NavigationStack {
                content
                    .messageNavigationTitle("编辑个人资料")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { cancelButton }
                        ToolbarItem(placement: .confirmationAction) { saveButton.buttonStyle(.borderedProminent) }
                    }
            }
            .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(452), .large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .background(ChirpTheme.canvas)
        .foregroundStyle(ChirpTheme.ink)
        .tint(ChirpTheme.accent)
        .interactiveDismissDisabled(hasChanges || isSaving || isPreparing)
        .alert("放弃未保存的更改？", isPresented: $confirmsDiscard) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        #if os(iOS)
        .photosPicker(isPresented: $showsPhotos, selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            prepareAvatar {
                guard let avatar = try await item.loadTransferable(type: SelectedAvatar.self) else {
                    throw ClientFailure(.avatarInvalid)
                }
                return avatar
            }
        }
        #endif
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.jpeg, .png, .heic, .heif]) { result in
            switch result {
            case .success(let url):
                prepareAvatar { try await Task.detached(priority: .userInitiated) { try SelectedAvatar(file: url) }.value }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { avatarError = .capture(error, fallback: .avatarInvalid) }
            }
        }
        .logScreen("editProfile")
        .onDisappear { work?.cancel() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                avatarCard
                nicknameField
                if let syncMessage { MessageText(syncMessage).font(.footnote).foregroundStyle(ChirpTheme.secondary) }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(ChirpTheme.canvas)
        .scrollDismissesKeyboard(.interactively)
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            if let saveError {
                let partial: LocalizedMessage = "昵称已保存，头像更改仍待保存。"
                let reason = saveError.localized(in: locale)
                Text(verbatim: nicknameAlreadySaved ? "\(partial.localized(in: locale))\n\(reason)" : reason)
            }
        }
    }

    private var avatarCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            MessageLabel("房间名片预览", systemImage: "person.text.rectangle")
                .font(.subheadline.weight(.medium)).foregroundStyle(ChirpTheme.accent)
            avatarPicker
                .disabled(isSaving || isPreparing)
                .messageAccessibilityLabel("更换头像")
                .accessibilityValue(Text(verbatim: previewName))
                .accessibilityIdentifier("change-profile-avatar")

            if isPreparing {
                HStack { ProgressView().controlSize(.small); MessageText("正在处理图片…") }
            } else if avatarDraft.isChanged {
                HStack {
                    if case .removal = avatarDraft { MessageText("保存后将使用昵称首字") }
                    else { MessageText("已选择新头像") }
                    Spacer(minLength: 4)
                    Button {
                        avatarDraft = .original
                        avatarError = nil
                    } label: {
                        MessageText("撤销").font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(ChirpTheme.accent)
                    .disabled(isSaving).accessibilityIdentifier("undo-profile-avatar")
                }
            } else {
                MessageText("JPEG、PNG 或 HEIC，小于 5 MB，居中裁剪。")
            }
            if let avatarError { FailureText(avatarError).foregroundStyle(ChirpTheme.danger).textSelection(.enabled) }
        }
        .font(.footnote).foregroundStyle(ChirpTheme.secondary)
        .padding(20)
        .background(alignment: .trailing) {
            ZStack {
                ForEach([92, 136, 180], id: \.self) { diameter in
                    Circle().stroke(ChirpTheme.accent.opacity(0.09), lineWidth: 1)
                        .frame(width: CGFloat(diameter), height: CGFloat(diameter))
                }
            }
            .offset(x: 78, y: 55)
            .accessibilityHidden(true).allowsHitTesting(false)
        }
        .background(ChirpTheme.hero)
        .clipShape(.rect(cornerRadius: ChirpTheme.Radius.card))
    }

    private var canRemoveAvatar: Bool {
        if case .removal = avatarDraft { return false }
        return hasAvatar
    }

    @ViewBuilder private var avatarPicker: some View {
        #if os(macOS)
        if canRemoveAvatar {
            avatarMenu
        } else {
            Button { showsFiles = true } label: { avatarPickerLabel }
                .buttonStyle(.plain)
        }
        #else
        avatarMenu
        #endif
    }

    private var avatarMenu: some View {
        Menu {
            #if os(iOS)
            Button("从照片选择", systemImage: "photo") { editingName = false; showsPhotos = true }
                .accessibilityIdentifier("choose-avatar-photo")
            #endif
            Button("选择图片文件", systemImage: "folder") { editingName = false; showsFiles = true }
                .accessibilityIdentifier("choose-avatar-file")
            if canRemoveAvatar {
                Button("移除头像", systemImage: "trash", role: .destructive) {
                    avatarDraft = .removal
                    avatarError = nil
                }
                .accessibilityIdentifier("remove-profile-avatar")
            }
        } label: { avatarPickerLabel }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    private var avatarPickerLabel: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                                                 : AnyLayout(HStackLayout(spacing: 18))
        return layout {
            avatarPreview
            VStack(alignment: .leading, spacing: 9) {
                Text(verbatim: previewName)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(ChirpTheme.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                    MessageText("更换头像")
                    #if os(macOS)
                    if canRemoveAvatar { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
                    #else
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    #endif
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(ChirpTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
    }

    private var avatarPreview: some View {
        let image: CGImage? = switch avatarDraft {
        case .original: savedAvatar
        case .replacement(let selected): selected.image
        case .removal: nil
        }
        return Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                IdentityAvatar(name: previewName, identity: memberID, size: 78)
                    .environment(\.memberProfiles, nil)
            }
        }
        .frame(width: 78, height: 78).clipShape(.circle)
        .padding(3).background(ChirpTheme.surface, in: .circle)
        .accessibilityHidden(true)
    }

    private var nicknameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                MessageText("昵称").font(.headline)
                Spacer()
                Text(verbatim: "\(count) / \(VoiceRooms.maxNameLength)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(nameError == nil ? ChirpTheme.secondary : ChirpTheme.danger)
                    .messageAccessibilityLabel("已输入 \(count) 个字符，最多 80 个")
            }
            HStack(spacing: 0) {
                TextField("输入昵称", text: Binding(get: { name }, set: { editedName = $0 == savedName ? nil : $0 }))
                    .textFieldStyle(.plain).font(.body)
                    .focused($editingName)
                    .messageAccessibilityLabel("昵称")
                    .accessibilityIdentifier("profile-nickname")
                    .onSubmit {
                        #if os(macOS)
                        save()
                        #else
                        editingName = false
                        #endif
                    }
                    .submitLabel(.done)
                if editingName && !name.isEmpty {
                    Button { editedName = ""; editingName = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(ChirpTheme.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).messageAccessibilityLabel("清空昵称")
                    .accessibilityIdentifier("clear-profile-nickname")
                }
            }
            .disabled(isSaving)
            .padding(.leading, 14).padding(.trailing, 4)
            .frame(minHeight: 48)
            .background(ChirpTheme.surface, in: .rect(cornerRadius: ChirpTheme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: ChirpTheme.Radius.control)
                    .strokeBorder(nameError != nil ? ChirpTheme.danger : (editingName ? ChirpTheme.accent : ChirpTheme.border),
                                  lineWidth: nameError != nil || editingName ? 2 : 1)
                    .allowsHitTesting(false)
            }
            if let nameError {
                MessageLabel(nameError, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(ChirpTheme.danger)
                    .accessibilityIdentifier("profile-nickname-error")
            } else {
                MessageText("支持中文、字母和表情。").font(.footnote).foregroundStyle(ChirpTheme.secondary)
            }
        }
    }

    private var cancelButton: some View {
        Button("取消") {
            if hasChanges || isPreparing { confirmsDiscard = true } else { dismiss() }
        }
        .disabled(isSaving)
        .accessibilityIdentifier("cancel-profile-edits")
    }

    private var saveButton: some View {
        Button { save() } label: {
            if isSaving { ProgressView().controlSize(.small).messageAccessibilityLabel("正在保存更改") }
            else {
                MessageText("保存")
                    #if os(iOS)
                    .opacity(canSave ? 1 : 0.45)
                    #endif
            }
        }
        .disabled(!canSave)
        .accessibilityIdentifier("save-profile")
    }

    private func prepareAvatar(_ load: @escaping @Sendable () async throws -> SelectedAvatar) {
        guard !isSaving, !isPreparing else { return }
        ClientLog.shared.record(.account, "chooseAvatar")
        isPreparing = true
        avatarError = nil
        work = Task {
            defer { isPreparing = false; selectedPhoto = nil }
            do {
                let avatar = try await load()
                try Task.checkCancellation()
                avatarDraft = .replacement(avatar)
            } catch {
                if !Task.isCancelled { avatarError = .capture(error, fallback: .avatarInvalid) }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        ClientLog.shared.record(.account, "saveProfile", outcome: .started)
        isSaving = true
        saveError = nil
        nicknameAlreadySaved = false
        editingName = false
        work = Task {
            defer { isSaving = false }
            do {
                if nameChanged {
                    try await apply(.nickname(trimmedName))
                    try Task.checkCancellation()
                    editedName = nil
                    nicknameAlreadySaved = true
                }
                switch avatarDraft {
                case .replacement(let avatar): try await apply(.replaceAvatar(avatar.data))
                case .removal: try await apply(.removeAvatar)
                case .original: break
                }
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { saveError = .capture(error) } }
        }
    }
}
