#if DEBUG
import ChirpMLS
import SwiftUI

/// Uses the shipping components with public, synthetic data and no login/media session.
struct RoomInformationPreview: View {
    private enum Scenario: String, CaseIterable {
        case ready, rotating, pending, severalPending, waitingForPeers, stale, solo
        var title: LocalizedMessage {
            switch self {
            case .ready: "正常通话"
            case .rotating: "正在换钥"
            case .pending: "等待身份核验"
            case .severalPending: "多台设备待核验"
            case .waitingForPeers: "等待其他成员互认"
            case .stale: "房间状态待同步"
            case .solo: "等朋友加入"
            }
        }
        var needsVerification: Bool { self == .pending || self == .severalPending || self == .waitingForPeers }
    }
    @State private var scenario = Scenario.ready
    @State private var showMember = false
    @State private var verificationTarget: MemberInfo?
    @State private var dark = ProcessInfo.processInfo.arguments.contains("--room-information-dark")
    @State private var volume = 1.0
    private let room = ChirpDesignSamples.rooms[0]
    private var member: CallMember {
        CallMember(id: "member_preview.login_preview.entry_preview", name: "小林", microphoneEnabled: scenario == .stale ? nil : !scenario.needsVerification, speaking: false,
                   listening: scenario == .stale ? nil : !scenario.needsVerification,
                   identityVerified: scenario != .pending && scenario != .severalPending)
    }
    private var additionalMember: CallMember {
        CallMember(id: "member_alex.login_preview.entry_preview", name: "Alex", microphoneEnabled: false, speaking: false,
                   listening: false, identityVerified: scenario != .severalPending)
    }
    private let localMember = CallMember(id: "member_me.login_preview.entry_preview", name: "Mira", microphoneEnabled: false, speaking: false,
                                         listening: true, identityVerified: true)
    private var targets: [MemberInfo] {
        switch scenario {
        case .pending:
            [MemberInfo(id: member.id, displayName: member.name)]
        case .severalPending:
            [member, additionalMember].map { MemberInfo(id: $0.id, displayName: $0.name) }
        default:
            []
        }
    }
    private var sampleDevice: V5Device {
        let account = SettingsDesignSamples.key(4), leaf = SettingsDesignSamples.key(5)
        return V5Device(accountKey: account, certificates: [V5Certificate(accountKey: account, deviceKey: leaf,
            issuerKey: account, parentHash: "", serial: Data(repeating: 6, count: 16).base64EncodedString(),
            canEnroll: true, notBefore: 1_790_000_000, notAfter: 1_890_000_000, signature: "")])
    }
    private var tracks: [CallTrackDiagnostic] {
        [CallTrackDiagnostic(id: "preview-audio", identity: member.id, muted: false, subscribed: true,
            encryption: .verified, quality: .good, lastDecryption: .now.advanced(by: .seconds(-12)),
            packetsReceived: 12_480, packetsLost: 3, jitterMS: 5.8, roundTripMS: 32)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                MessageText("离线设计预览 · 示例数据").font(.caption).foregroundStyle(ChirpTheme.secondary)
                Spacer()
                Menu {
                    ForEach(Scenario.allCases, id: \.self) { value in
                        Button { scenario = value } label: { MessageText(value.title) }
                    }
                } label: { MessageLabel(scenario.title, systemImage: "slider.horizontal.3") }
                    .accessibilityIdentifier("room-preview-scenario")
                Toggle("深色", isOn: $dark).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel(Text("深色")).accessibilityIdentifier("room-preview-dark")
            }
            .padding(16).background(ChirpTheme.surface)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    RoomHeader(room: room,
                               accessory: RoomPublicInformationButton(room: room, information: sampleInformation,
                                   trust: scenario.needsVerification ? .pending : scenario == .solo ? .solo : .trusted))
                    ChirpSectionHeading(title: "在这里", detail: "示例数据")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], alignment: .leading, spacing: 12) {
                        if scenario != .solo {
                            Button { showMember = true } label: {
                                MemberCard(member: member, canAdjustAudio: true, allowsIdentityAction: false,
                                           requiresVerification: !member.identityVerified)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("preview-member-information")
                            .popover(isPresented: $showMember) { memberInformation }
                            MemberCard(member: additionalMember, requiresVerification: !additionalMember.identityVerified)
                        }
                        MemberCard(member: localMember)
                    }
                }.frame(maxWidth: 760).padding(24).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("preview-room-scroll")
            .roomVerificationStatus(isPending: scenario.needsVerification, targets: targets) { entry in
                verificationTarget = targets.first { $0.id == entry }
            }
        }
        .background(ChirpTheme.canvas).tint(ChirpTheme.accent)
        .preferredColorScheme(dark ? .dark : .light)
        .dynamicTypeSize(.large)
        .sheet(item: $verificationTarget) { target in
            SASVerificationContent(name: target.displayName, identity: target.id, device: nil, step: .preparation) { action in
                if case .close = action { verificationTarget = nil }
            }
            .preferredColorScheme(dark ? .dark : .light)
        }
    }

    private var memberInformation: some View {
        MemberInformationContent(member: member, fallbackName: member.name, identity: member.id,
            status: scenario.needsVerification ? "等待设备互认" : "已验证音频解密",
            tracks: scenario.needsVerification ? [] : tracks, volume: $volume, isFriend: true, device: sampleDevice, verify: nil)
            .dynamicTypeSize(.large)
            .presentationCompactAdaptation(.sheet)
            .preferredColorScheme(dark ? .dark : .light)
    }

    private var sampleInformation: RoomPublicInformation {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        var info = GroupRoomInformation(serverTimeMS: now, rotationIntervalMS: 60_000,
            keyEpoch: scenario.needsVerification || scenario == .solo ? 0 : 11,
            memberCount: scenario == .solo ? 1 : 3, updateReason: scenario.needsVerification ? "members_changed" : "scheduled_rotation",
            establishedAtMS: scenario.needsVerification ? nil : now - 80_000,
            lastRotationAtMS: scenario.needsVerification || scenario == .solo ? nil : now - 20_000,
            nextRotationAtMS: scenario.needsVerification ? nil : now + 40_000)
        if scenario == .rotating {
            info.rotationPhase = "switching"; info.rotationEpoch = 12
            info.confirmedMembers = 3; info.activatedMembers = 2
        }
        return RoomPublicInformation(groupID: "preview", information: info, requestStartedAt: .now, unavailable: scenario == .stale)
    }
}
#endif
