import ChirpMLS
import SwiftUI

struct MemberInformationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.roomIdentity) private var room
    @ObservedObject var call: CallController
    let memberID: String
    let fallbackName: String
    let requestVerification: (String) -> Void

    private var member: CallMember? { call.members.first { $0.id == memberID } }
    private var peer: MLSPeer? { room?.remotePeer(for: memberID) }
    private var isFriend: Bool {
        guard let peer, let device = peer.binding?.device else { return false }
        return room?.social.friends.contains { $0.accountID == MemberProfile.memberID(for: memberID) && $0.accountKey == device.accountKey } == true
    }

    var body: some View {
        MemberInformationContent(member: member, fallbackName: fallbackName, identity: memberID,
            status: call.audioStatus(for: memberID).title, tracks: call.trackDiagnostics.filter { $0.identity == memberID },
            volume: Binding(get: { call.memberVolumes[memberID] ?? 1 }, set: { call.setMemberVolume($0, for: memberID) }),
            canAdjustVolume: call.canAdjustVolume(for: memberID), listening: call.isListening, isFriend: isFriend,
            device: peer?.binding?.device,
            volumeCommitted: { call.recordVolumeChange() },
            verify: peer == nil ? nil : { requestVerification(memberID); dismiss() })
    }
}

struct MemberInformationContent: View {
    let member: CallMember?
    let fallbackName: String
    let identity: String
    let status: LocalizedMessage
    let tracks: [CallTrackDiagnostic]
    @Binding var volume: Double
    var canAdjustVolume = true
    var listening = true
    var isFriend = false
    var device: V5Device?
    var volumeCommitted: () -> Void = {}
    var verify: (() -> Void)?
    @State private var connectionExpanded = false
    @State private var identityExpanded = false
    @State private var showFingerprint = false
    @State private var unmutedVolume = 1.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MessageText("成员信息").font(.subheadline.weight(.semibold)).foregroundStyle(ChirpTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                hero
                if member != nil { volumeControls }
                MessageLabel(member == nil ? "这位成员已离开房间" : status, systemImage: member == nil ? "person.crop.circle.badge.minus" : "headphones")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
                    .accessibilityIdentifier("member-audio-summary")
                if let verify, member != nil, member?.identityVerified != true {
                    Button(action: verify) {
                        MessageLabel("添加好友或核验当前设备", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).tint(ChirpTheme.accent)
                        .accessibilityIdentifier("member-verify-device")
                }
                RoomInformationGroup(title: "连接详情", expanded: $connectionExpanded) {
                    if member == nil { MessageText("这位成员已离开房间") }
                    else if tracks.isEmpty { MessageText(status) }
                    else {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            if tracks.count > 1 {
                                let number = index + 1
                                MessageText("音轨 \(number)").font(.caption.weight(.medium))
                            }
                            trackDetails(track)
                        }
                    }
                    MessageText("这些信息来自本机接收侧观测。")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
                RoomInformationGroup(title: "好友与设备", expanded: $identityExpanded) {
                    RoomDetailRow(title: "好友关系") { MessageText(isFriend ? "你的好友" : "房间成员") }
                    RoomDetailRow(title: "当前设备") {
                        MessageText(member == nil ? "这位成员已离开房间" : member?.identityVerified == true ? "你已信任当前设备" : "尚未核验当前设备")
                    }
                    RoomDetailRow(title: "账号标识") {
                        Text(verbatim: MemberProfile.memberID(for: identity)).textSelection(.enabled)
                    }
                    if let device {
                        if showFingerprint {
                            IdentityFingerprint(key: device.accountKey, title: "账号指纹")
                            IdentityFingerprint(key: device.leafKey, title: "当前设备指纹")
                        } else if let fingerprint = try? V5Crypto.fingerprint(device.leafKey) {
                            RoomDetailRow(title: "设备指纹摘要") {
                                Text(verbatim: String(fingerprint.prefix(8)) + "…" + String(fingerprint.suffix(8)))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        Button { showFingerprint.toggle() } label: {
                            MessageText(showFingerprint ? "收起完整设备指纹" : "查看完整设备指纹").frame(minHeight: 44)
                        }.buttonStyle(.plain).foregroundStyle(ChirpTheme.accent)
                            .accessibilityIdentifier("member-full-fingerprint")
                    }
                    MessageText("好友关系和个人信任状态仅在你的视角展示。")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                    if let verify, member?.identityVerified == true {
                        Button(action: verify) {
                            MessageLabel(member?.identityVerified == true ? "重新核验当前设备" : "添加好友或核验当前设备", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered).tint(ChirpTheme.accent)
                            .accessibilityIdentifier("member-verify-device")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .logScreen("memberInformation")
        .onChange(of: connectionExpanded) { ClientLog.shared.record(.navigation, connectionExpanded ? "expandConnection" : "collapseConnection") }
        .onChange(of: identityExpanded) { ClientLog.shared.record(.navigation, identityExpanded ? "expandIdentity" : "collapseIdentity") }
        .onChange(of: showFingerprint) { ClientLog.shared.record(.navigation, showFingerprint ? "showFingerprint" : "hideFingerprint") }
        .background(ChirpTheme.canvas)
        .tint(ChirpTheme.accent)
        #if os(macOS)
        .frame(width: 400, height: 600)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .accessibilityIdentifier("member-information")
    }

    private var hero: some View {
        VStack(spacing: 12) {
            IdentityAvatar(name: member?.name ?? fallbackName, identity: identity, size: 68)
            Text(member?.name ?? fallbackName).font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(ChirpTheme.ink).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let member {
                MemberAudioStatus(member: member)
                    .font(.subheadline.weight(.medium))
                    .labelStyle(.titleAndIcon)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { badges }
                VStack(spacing: 8) { badges }
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    @ViewBuilder private var badges: some View {
        if isFriend { ChirpBadge(title: "你的好友", systemImage: "person.crop.circle") }
        if member != nil {
            ChirpBadge(title: member?.identityVerified == true ? "你已信任当前设备" : "尚未核验当前设备",
                       systemImage: member?.identityVerified == true ? "checkmark.shield" : "exclamationmark.shield",
                       emphasized: member?.identityVerified == true)
        }
    }

    private var volumeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MessageText("你听到的音量").font(.subheadline.weight(.semibold))
                Spacer()
                Text(volume.formatted(.percent.precision(.fractionLength(0))))
                    .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(ChirpTheme.accent)
                    .accessibilityIdentifier("member-volume-value")
            }.accessibilityElement(children: .contain)
            Slider(value: $volume, in: 0...2, step: 0.05, onEditingChanged: { if !$0 { volumeCommitted() } }) {
                MessageText("成员音量")
            }.labelsHidden().disabled(!canAdjustVolume).accessibilityIdentifier("member-playback-volume")
            MessageLabel(listening ? "只影响你听到的声音" : "房间收听已暂停", systemImage: "headphones")
                .font(.caption).foregroundStyle(ChirpTheme.secondary)
            HStack(spacing: 10) {
                Button {
                    if volume == 0 { volume = unmutedVolume > 0 ? unmutedVolume : 1 }
                    else { unmutedVolume = volume; volume = 0 }
                    volumeCommitted()
                } label: { MessageText(volume == 0 ? "恢复收听" : "本机静音").frame(minHeight: 32) }
                    .accessibilityIdentifier("member-local-mute")
                Button { volume = 1; volumeCommitted() } label: { MessageText("恢复 100%").frame(minHeight: 32) }
                    .accessibilityIdentifier("member-volume-reset")
            }.buttonStyle(.bordered).disabled(!canAdjustVolume)
        }
        .chirpSurface(padding: 16)
    }

    @ViewBuilder private func trackDetails(_ track: CallTrackDiagnostic) -> some View {
        RoomDetailRow(title: "网络质量") { MessageText(track.quality.title) }
        RoomDetailRow(title: "订阅状态") { MessageText(track.subscribed ? "已订阅" : "未订阅") }
        RoomDetailRow(title: "音轨加密") { MessageText(encryptionTitle(track.encryption)) }
        metric("抖动", track.jitterMS)
        metric("往返时延", track.roundTripMS)
        if let value = track.packetsLost { RoomDetailRow(title: "累计丢包") { Text(value.formatted()) } }
        if let value = track.packetsReceived { RoomDetailRow(title: "累计收包") { Text(value.formatted()) } }
        if let last = track.lastDecryption {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let number = Int(max(0, min(86_400, last.duration(to: .now).components.seconds)))
                MessageText("最近解密成功事件：\(number) 秒前").font(.caption).foregroundStyle(ChirpTheme.secondary)
            }
            MessageText("静音时事件可能不更新，不代表音频连接中断。")
                .font(.caption).foregroundStyle(ChirpTheme.secondary)
        }
    }

    private func encryptionTitle(_ encryption: CallTrackEncryption) -> LocalizedMessage {
        switch encryption {
        case .waiting: "等待有效的加密音频"
        case .verified: "已验证音频解密"
        case .missingKey: "等待本轮密钥"
        case .decryptionFailed: "音频解密暂时异常"
        case .failed: "音轨加密异常"
        }
    }

    @ViewBuilder private func metric(_ title: LocalizedMessage, _ value: Double?) -> some View {
        if let value = CallDiagnosticSample.boundedMetric(value) {
            RoomDetailRow(title: title) { Text(value.formatted(.number.precision(.fractionLength(1))) + " ms").monospacedDigit() }
        }
    }
}
