import ChirpMLS
import SwiftUI

struct FriendsView: View {
    @Environment(ApplicationSession.self) private var application
    @State private var query = ""
    #if DEBUG
    @Environment(\.chirpDesignPreview) private var isPreview
    #endif
    private var social: SocialIdentity { application.social }
    private var failure: String? {
        #if DEBUG
        if isPreview { return nil }
        #endif
        return social.failure
    }
    private var friends: [IdentityFriend] {
        #if DEBUG
        if isPreview { return SettingsDesignSamples.friends }
        #endif
        return social.friends
    }
    private var filteredFriends: [IdentityFriend] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return friends.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.accountID.localizedStandardContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsPageHeading(title: "只向信任的人开口", subtitle: "声音只属于你们，其余皆是风声", systemImage: "person.2")
                    if let failure { SettingsFailure(message: failure) }
                    if friends.isEmpty {
                        if social.isRefreshing {
                            ProgressView().frame(maxWidth: .infinity).padding(32)
                        } else {
                            SettingsEmptyState(title: "还没有好友", subtitle: "进入房间，点击成员头像即可添加好友。", systemImage: "person.2")
                                .accessibilityIdentifier("friends-empty")
                        }
                    } else if filteredFriends.isEmpty {
                        SettingsEmptyState(title: "没有找到好友", subtitle: "试试其他昵称或用户编号。", systemImage: "magnifyingglass")
                    } else {
                        ChirpSectionHeading(title: "好友", detail: "\(filteredFriends.count) 位好友")
                        LazyVStack(spacing: 12) {
                            ForEach(filteredFriends) { friend in
                                NavigationLink {
                                    FriendDetailView(friend: friend)
                                } label: { FriendRow(friend: friend, blocked: isBlocked(friend)) }
                                .buttonStyle(.plain).accessibilityIdentifier("friend-\(friend.id)")
                            }
                        }
                    }
                }
                .frame(maxWidth: 720).padding(24).frame(maxWidth: .infinity)
            }
            .background(ChirpTheme.canvas)
            .messageNavigationTitle("好友")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索好友"))
            #else
            .searchable(text: $query, prompt: Text("搜索好友"))
            #endif
            .refreshable { await social.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await social.refresh() } } label: { MessageLabel("刷新好友", systemImage: "arrow.clockwise") }
                        .disabled(social.isRefreshing).accessibilityIdentifier("refresh-friends")
                }
            }
        }
        .tint(ChirpTheme.accent)
        .task { await social.refresh() }
        .accessibilityIdentifier("friends-page")
    }

    private func isBlocked(_ friend: IdentityFriend) -> Bool {
        social.blacklist.contains { $0.kind == "account" && ($0.subject == friend.accountID || $0.accountKey == friend.accountKey) }
    }
}

private struct FriendRow: View {
    let friend: IdentityFriend
    let blocked: Bool

    var body: some View {
        HStack(spacing: 16) {
            IdentityAvatar(name: friend.name, identity: friend.accountID, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: friend.name).font(.headline).foregroundStyle(ChirpTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if blocked {
                    MessageLabel("账号已被拉黑", systemImage: "hand.raised").font(.caption).foregroundStyle(ChirpTheme.danger)
                } else {
                    MessageLabel(friend.trustedDevices.isEmpty ? "尚未核验设备" : "\(friend.trustedDevices.count) 台已信任设备", systemImage: friend.trustedDevices.isEmpty ? "shield" : "checkmark.shield")
                        .font(.caption).foregroundStyle(ChirpTheme.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(ChirpTheme.secondary).accessibilityHidden(true)
        }
        .chirpSurface(padding: 18).contentShape(.rect)
    }
}

private struct FriendDetailView: View {
    let friend: IdentityFriend
    @Environment(ApplicationSession.self) private var application
    @Environment(LoginSession.self) private var login
    @Environment(\.dismiss) private var dismiss
    @State private var pendingAction: Action?
    @State private var isUpdating = false
    #if DEBUG
    @Environment(\.chirpDesignPreview) private var isPreview
    #endif
    private enum Action: Identifiable {
        case remove, untrust(String)
        var id: String { switch self { case .remove: "remove"; case .untrust(let key): key } }
    }
    private var social: SocialIdentity { application.social }
    private var current: IdentityFriend { social.friends.first(where: { $0.id == friend.id }) ?? friend }
    private var failure: String? {
        #if DEBUG
        if isPreview { return nil }
        #endif
        return social.failure
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        IdentityAvatar(name: current.name, identity: current.accountID, size: 64)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: current.name).font(.title2.weight(.semibold)).foregroundStyle(ChirpTheme.ink)
                            Text(verbatim: current.accountID).font(.caption).foregroundStyle(ChirpTheme.secondary).textSelection(.enabled)
                        }
                    }
                    IdentityFingerprint(key: current.accountKey, title: "账号指纹")
                }.chirpSurface(padding: 20)
                ChirpSectionHeading(title: "已信任设备", detail: "\(current.trustedDevices.count) 台设备")
                if current.trustedDevices.isEmpty {
                    SettingsEmptyState(title: "尚未核验设备", subtitle: "在同一个房间中核对安全码后，可建立设备信任。", systemImage: "shield")
                } else {
                    ForEach(current.trustedDevices.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 14) {
                            if deviceBlocked(key) {
                                SettingsStatus(title: "已永久撤销", systemImage: "xmark.shield", color: ChirpTheme.danger)
                            } else { SettingsStatus(title: "已信任", systemImage: "checkmark.shield") }
                            IdentityFingerprint(key: key)
                            Button(role: .destructive) { pendingAction = .untrust(key) } label: { MessageLabel("撤销个人信任", systemImage: "minus.circle").frame(minHeight: 32) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .tint(ChirpTheme.danger).disabled(login.session == nil)
                        }.chirpSurface(padding: 20)
                    }
                }
                MessageText("删除好友或撤销个人信任会同步到本人其他设备，不封禁对方账号。")
                    .font(.caption).foregroundStyle(ChirpTheme.secondary)
                if let failure { SettingsFailure(message: failure) }
                Button(role: .destructive) { pendingAction = .remove } label: {
                    MessageLabel("删除好友", systemImage: "person.badge.minus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered).tint(ChirpTheme.danger).disabled(login.session == nil)
                .accessibilityIdentifier("remove-friend")
                if isUpdating { ProgressView().frame(maxWidth: .infinity) }
            }
            .frame(maxWidth: 640).padding(24).frame(maxWidth: .infinity)
        }
        .logScreen("friendDetails")
        .background(ChirpTheme.canvas).navigationTitle(Text(verbatim: current.name))
        .disabled(isUpdating)
        .confirmationDialog("管理好友与信任", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            if let action = pendingAction {
                Button(role: .destructive) { pendingAction = nil; perform(action) } label: {
                    switch action {
                    case .remove: MessageText("删除好友及其全部设备信任")
                    case .untrust: MessageText("撤销个人信任")
                    }
                }
            }
        } message: {
            MessageText("删除好友或撤销个人信任会同步到本人其他设备，不封禁对方账号。")
        }
    }

    private func deviceBlocked(_ key: String) -> Bool {
        social.blacklist.contains { ($0.kind == "device" && $0.subject == key) || ($0.kind == "account" && ($0.subject == current.accountID || $0.accountKey == current.accountKey)) }
    }
    private func perform(_ action: Action) {
        isUpdating = true
        Task {
            defer { isUpdating = false }
            let key: String?
            switch action { case .remove: key = nil; case .untrust(let deviceKey): key = deviceKey }
            await social.change(operation: key == nil ? "remove_friend" : "untrust", friendID: current.accountID,
                device: V5Device(accountKey: current.accountKey, certificates: []), name: current.name, deviceKey: key)
            if !social.friends.contains(where: { $0.id == friend.id }) { dismiss() }
        }
    }
}
