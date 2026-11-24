import SwiftUI

struct RoomPasswordSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var call: CallController
    let room: RoomOverview
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: ClientFailure?
    @State private var submission: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        #if os(iOS)
        let formHeight: CGFloat = call.hasSession || errorMessage != nil ? 348 : 284
        #endif
        VStack(spacing: 0) {
            #if os(macOS)
            form().padding(24)
            Divider()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("取消", action: cancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                joinButton.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            #else
            GeometryReader { sheet in
                let compact = sheet.size.height < 250
                ScrollView {
                    VStack(spacing: compact ? 10 : 24) {
                        form(compact: compact)
                        joinButton.controlSize(compact ? .regular : .large)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, compact ? 10 : 24)
                    .padding(.bottom, compact ? 8 : 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
            #endif
        }
        .background(ChirpTheme.canvas)
        .tint(ChirpTheme.accent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        #if os(macOS)
        .frame(width: 420)
        .presentationSizing(.fitted)
        #else
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(formHeight), .large])
        .presentationDragIndicator(.visible)
        #endif
        .interactiveDismissDisabled(isSubmitting)
        .logScreen("roomPassword")
        .task { focused = true }
        .onDisappear { password = ""; submission?.cancel() }
    }

    private func form(compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(ChirpTheme.accent)
                    .frame(width: compact ? 40 : 50, height: compact ? 40 : 50)
                    .background(ChirpTheme.hero, in: .rect(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    MessageText("密码房间").font(.caption.weight(.semibold)).foregroundStyle(ChirpTheme.accent)
                    Text(room.localizedDisplayName(in: locale))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(ChirpTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                #if os(iOS)
                Button(action: cancel) {
                    MessageLabel("取消", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ChirpTheme.secondary)
                .disabled(isSubmitting)
                .accessibilityIdentifier("cancel-room-password")
                #endif
            }
            if call.hasSession {
                MessageText("输入密码即可加入。验证通过前，你会留在当前通话中。")
                    .font(.callout).foregroundStyle(ChirpTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                MessageText("房间密码").font(.subheadline.weight(.medium)).foregroundStyle(ChirpTheme.ink)
                    .accessibilityHidden(true)
                SecureField("房间密码", text: $password, prompt: Text("输入密码"))
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(ChirpTheme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(ChirpTheme.surface, in: .rect(cornerRadius: ChirpTheme.Radius.control))
                    .overlay {
                        RoundedRectangle(cornerRadius: ChirpTheme.Radius.control)
                            .strokeBorder(focused ? ChirpTheme.accent : ChirpTheme.border, lineWidth: focused ? 1.5 : 1)
                            .allowsHitTesting(false)
                    }
                    .focused($focused)
                    .disabled(isSubmitting)
                    .onSubmit(submit)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.join)
                    #endif
                    .accessibilityIdentifier("room-password-input")
                if let errorMessage {
                    Label { FailureText(errorMessage) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                        .font(.callout).foregroundStyle(ChirpTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("room-password-error")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var joinButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if isSubmitting { ProgressView().controlSize(.small).accessibilityHidden(true) }
                MessageText(isSubmitting ? "正在验证入房" : "验证并加入").fontWeight(.semibold)
            }
            #if os(iOS)
            .frame(maxWidth: .infinity, minHeight: 32)
            #endif
            .modifier(ChirpProminentLabelStyle())
        }
        .buttonStyle(.glassProminent)
        .disabled(isSubmitting)
        .accessibilityIdentifier("submit-room-password")
    }

    private func cancel() {
        password = ""
        dismiss()
    }

    private func submit() {
        guard !isSubmitting else { return }
        guard password.utf8.count <= 512 else { errorMessage = ClientFailure(.passwordTooLong); return }
        isSubmitting = true; errorMessage = nil
        submission = Task {
            defer { isSubmitting = false }
            do {
                try await call.startJoin(room: room, password: password.isEmpty ? nil : password)
                password = ""; dismiss()
            } catch is CancellationError { password = "" }
            catch { errorMessage = ClientFailure.capture(error); focused = true }
        }
    }
}
