import SwiftUI

extension EnvironmentValues {
    @Entry var roomIdentity: RoomIdentity? = nil
    @Entry var memberProfiles: MemberProfiles? = nil
}

extension CallController {
    var canToggleMicrophone: Bool { (isConnected || (hasSession && !isMuted)) && preparingRoomID == nil && !isChangingMicrophone && !isChangingAudioPreset }

    var roomSummary: LocalizedMessage {
        if isConnected { return "\(members.count) 位成员在线" }
        if isBusy || hasSession { return status }
        return "私密语音 · 人数不限"
    }

    var microphoneSummary: LocalizedMessage {
        if isChangingMicrophone { return "正在更新麦克风" }
        return isMuted ? "麦克风已静音" : "麦克风已开启"
    }
}

extension AudioPreset {
    var shortTitle: LocalizedMessage { title }
}

struct RoomEmblem: View {
    var size: CGFloat = 56

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(ChirpTheme.onAccent)
            .frame(width: size, height: size)
            .background(ChirpTheme.accent, in: .rect(cornerRadius: size * 0.32))
            .accessibilityHidden(true)
    }
}

struct IdentityAvatar: View {
    @Environment(\.memberProfiles) private var profiles
    let name: String
    let identity: String
    var size: CGFloat = 40
    var isSpeaking = false

    var body: some View {
        let colors = ChirpTheme.avatarColors(for: identity)
        Group {
            if let image = profiles?.image(for: identity) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Text(String((profiles?.displayName(for: identity, fallback: name) ?? name).prefix(1)).uppercased())
                    .font(.system(size: size * 0.38, weight: .medium, design: .rounded))
                    .foregroundStyle(colors.ink)
            }
        }
            .frame(width: size, height: size)
            .background(colors.fill, in: .circle)
            .clipShape(.circle)
            .overlay {
                Circle().strokeBorder(isSpeaking ? ChirpTheme.accent : .clear, lineWidth: 2)
                    .padding(-4)
            }
            .accessibilityHidden(true)
    }
}

struct MemberAvatar: View {
    @Environment(\.roomIdentity) private var room
    let member: CallMember
    var size: CGFloat = 40
    var allowsIdentityAction = true
    var body: some View {
        Group {
            if allowsIdentityAction, let room, let peer = room.remotePeer(for: member.id) {
                Button { room.presentVerification(peer) } label: {
                    avatar.frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }.buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: member.name)).messageAccessibilityHint("添加好友或核验当前设备")
                    .accessibilityIdentifier("member-identity-\(member.id)")
                    .help(Text("添加好友或核验当前设备"))
            } else { avatar }
        }
    }
    private var avatar: some View { IdentityAvatar(name: member.name, identity: member.id, size: size, isSpeaking: member.isSpeaking) }
}

struct MemberAudioStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let member: CallMember

    private var microphoneTitle: LocalizedMessage {
        switch member.microphoneEnabled {
        case true: member.isSpeaking ? "正在讲话" : "麦克风已开启"
        case false: "麦克风已静音"
        case nil: "麦克风状态待同步"
        }
    }

    private var playbackTitle: LocalizedMessage {
        switch member.listening {
        case true: "房间收听已开启"
        case false: "房间收听已暂停"
        case nil: "收听状态待同步"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            indicator(microphoneTitle, symbol: member.isSpeaking ? "mic.and.signal.meter.fill" : "mic.fill",
                      offSymbol: "mic.slash.fill", enabled: member.microphoneEnabled)
                .symbolEffect(.variableColor, isActive: member.isSpeaking && !reduceMotion)
                .accessibilityIdentifier("member-microphone-state")
            indicator(playbackTitle, symbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill", enabled: member.listening)
                .accessibilityIdentifier("member-listening-state")
        }
    }

    private func indicator(_ title: LocalizedMessage, symbol: String, offSymbol: String, enabled: Bool?) -> some View {
        Label {
            MessageText(title)
        } icon: {
            HStack(spacing: 1) {
                Image(systemName: enabled == false ? offSymbol : symbol)
                if enabled == nil { Image(systemName: "questionmark").imageScale(.small) }
            }
        }
        .foregroundStyle(enabled == true ? ChirpTheme.accent : ChirpTheme.secondary)
        .accessibilityElement(children: .ignore)
        .messageAccessibilityLabel(title)
        .messageHelp(title)
    }
}

struct MemberRow: View {
    let member: CallMember

    var body: some View {
        HStack(spacing: 14) {
            MemberAvatar(member: member)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(member.name).font(.body.weight(.medium)).foregroundStyle(ChirpTheme.ink)
                    if member.identityVerified { Image(systemName: "checkmark.shield.fill").foregroundStyle(ChirpTheme.accent).messageAccessibilityLabel("身份签名已核验") }
                }
                MemberAudioStatus(member: member).font(.caption).labelStyle(.iconOnly)
            }
            Spacer(minLength: 0)
            if member.isSpeaking {
                Image(systemName: "waveform").foregroundStyle(ChirpTheme.accent).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct MemberCard: View {
    let member: CallMember
    var canAdjustAudio = false
    var allowsIdentityAction = true
    var requiresVerification = false

    private var status: LocalizedMessage {
        if requiresVerification { return "待你核验" }
        return member.identityVerified ? "身份签名已核验" : "等待身份核验"
    }
    private var statusTint: Color {
        if requiresVerification { return ChirpTheme.roomVerificationInk }
        return member.identityVerified ? ChirpTheme.accent : ChirpTheme.secondary
    }
    private var border: Color {
        if requiresVerification { return ChirpTheme.roomVerificationInk.opacity(0.46) }
        return member.isSpeaking ? ChirpTheme.accent : ChirpTheme.border
    }

    var body: some View {
        VStack(spacing: 18) {
            MemberAvatar(member: member, size: 60, allowsIdentityAction: allowsIdentityAction).padding(.top, 8)
            VStack(spacing: 8) {
                Text(member.name).font(.subheadline.weight(.semibold)).foregroundStyle(ChirpTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                MessageLabel(status, systemImage: member.identityVerified && !requiresVerification ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.caption).foregroundStyle(statusTint)
                MemberAudioStatus(member: member)
                    .font(.callout.weight(.semibold))
                    .labelStyle(.iconOnly)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 148)
        .padding(16)
        .background(member.isSpeaking ? ChirpTheme.surfaceSubtle : ChirpTheme.surface,
                    in: .rect(cornerRadius: ChirpTheme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: ChirpTheme.Radius.card)
                .strokeBorder(border, lineWidth: requiresVerification || member.isSpeaking ? 1.5 : 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if canAdjustAudio {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
                    .padding(14).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct DirectoryMemberCard: View {
    let member: MemberInfo

    var body: some View {
        VStack(spacing: 18) {
            IdentityAvatar(name: member.displayName, identity: member.id, size: 56)
            VStack(spacing: 6) {
                Text(member.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(ChirpTheme.ink).lineLimit(2)
                MessageText("房间成员").font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 142)
        .chirpSurface(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionStatusLabel: View {
    @ObservedObject var call: CallController

    var body: some View {
        Label {
            MessageText(call.preparingRoomID != nil ? "正在验证入房" : call.status)
        } icon: {
            if call.phase == .verifying {
                Image(systemName: "exclamationmark.shield")
            } else if call.preparingRoomID != nil || call.isBusy || (call.hasSession && !call.isConnected) {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(call.isConnected ? ChirpTheme.accent : ChirpTheme.secondary.opacity(0.6))
                    .frame(width: 6, height: 6)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(call.isConnected ? ChirpTheme.accent : ChirpTheme.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct CallNotice: View {
    let message: ClientFailure

    var body: some View {
        Label { FailureText(message) } icon: { Image(systemName: "exclamationmark.circle.fill") }
            .font(.callout)
            .foregroundStyle(ChirpTheme.danger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(ChirpTheme.danger.opacity(0.08), in: .rect(cornerRadius: ChirpTheme.Radius.control))
            .textSelection(.enabled)
            .accessibilityIdentifier("call-error")
    }
}

struct CallControlsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if DEBUG
    @Environment(\.chirpDesignPreview) private var isDesignPreview
    #endif
    @ObservedObject var call: CallController
    let room: RoomOverview
    #if os(macOS)
    let showAudioSettings: () -> Void
    #endif
    @State private var passwordRoom: RoomOverview?

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        Group {
            if call.currentRoomID == room.roomID && call.preparingRoomID == nil && !call.isBusy {
                #if os(macOS)
                MacRoomCallActions(call: call, showAudioSettings: showAudioSettings)
                #else
                standardControls { sessionButtons }
                    .labelStyle(RoomCallLabelStyle())
                #endif
            } else {
                standardControls { entryButtons }
            }
        }
        .sheet(item: $passwordRoom) { target in RoomPasswordSheet(call: call, room: target) }
    }

    private func standardControls<Controls: View>(@ViewBuilder _ controls: () -> Controls) -> some View {
        GlassEffectContainer(spacing: 10) {
            layout { controls() }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
        }
        #if DEBUG
        .disabled(isDesignPreview)
        #endif
    }

    @ViewBuilder private var entryButtons: some View {
        if call.preparingRoomID != nil {
            #if os(iOS)
            progressBadge("正在验证入房")
            #endif
        } else if call.isBusy {
            #if os(iOS)
            progressBadge(call.status)
            #endif
            Button(action: call.leave) {
                MessageLabel("取消连接", systemImage: "xmark").modifier(CallControlLabelStyle())
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("cancel-join")
        } else {
            Button(action: requestJoin) {
                MessageLabel(room.passwordRequired ? "输入密码加入" : call.hasSession ? "切换到此房间" : "加入语音",
                             systemImage: room.passwordRequired ? "lock.fill" : "phone.fill").modifier(CallControlLabelStyle())
                    .modifier(ChirpProminentLabelStyle())
            }
            .buttonStyle(.glassProminent)
            .tint(ChirpTheme.accent)
            .disabled(call.isChangingAudioPreset)
            .accessibilityIdentifier("join-call")
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    #if os(iOS)
    private func progressBadge(_ status: LocalizedMessage) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            MessageText(status).font(.callout)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 48)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder private var sessionButtons: some View {
        Button(action: call.toggleMute) {
            MessageLabel(call.isMuted ? "打开麦克风" : "关闭麦克风",
                  systemImage: call.isMuted ? "mic.slash.fill" : "mic.fill")
        }
        .buttonStyle(.glass)
        .disabled(!call.canToggleMicrophone)
        .accessibilityIdentifier("toggle-microphone")
        .messageAccessibilityValue(call.microphoneSummary)
        .keyboardShortcut("m", modifiers: [.command, .shift])

        RoomAudioOutputButton(audio: call.audio)
            .disabled(call.isChangingMicrophone || call.isChangingAudioPreset)

        Button(role: .destructive, action: call.leave) {
            MessageLabel("离开语音", systemImage: "phone.down.fill")
        }
        .buttonStyle(.glassProminent)
        .tint(ChirpTheme.danger)
        .accessibilityIdentifier("leave-call")
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
    #endif

    private func requestJoin() {
        let target = room
        if target.passwordRequired { passwordRoom = target; return }
        Task {
            do { try await call.startJoin(room: target) }
            catch let error as APIError where error.needsRoomPassword { passwordRoom = target }
            catch { call.reportJoinError(error) }
        }
    }
}

struct RoomCallLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title3.weight(.medium)).frame(minHeight: 19)
            configuration.title.font(.subheadline.weight(.medium))
                .lineLimit(2, reservesSpace: dynamicTypeSize.isAccessibilitySize)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 48)
        .contentShape(.rect)
    }
}

private struct CallControlLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.font(.body.weight(.medium)).frame(minWidth: 108, minHeight: 28)
        #else
        content.font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 30)
        #endif
    }
}

#Preview("成员状态") {
    VStack(spacing: 24) {
        MemberRow(member: CallMember(id: "1", name: "小林", microphoneEnabled: true, speaking: true, listening: true))
        MemberRow(member: CallMember(id: "2", name: "Alex", microphoneEnabled: false, speaking: false, listening: false))
        MemberCard(member: CallMember(id: "3", name: "阿远", microphoneEnabled: true, speaking: false, listening: nil))
    }
    .padding(32)
    .frame(width: 340)
}

struct DirectoryMemberRow: View {
    let member: MemberInfo
    var body: some View {
        HStack(spacing: 12) {
            IdentityAvatar(name: member.displayName, identity: member.id, size: 36)
            Text(member.displayName).font(.body).foregroundStyle(ChirpTheme.ink)
        }
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
    }
}
