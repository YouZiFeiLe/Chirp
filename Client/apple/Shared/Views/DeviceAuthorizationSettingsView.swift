import SwiftUI

struct DeviceAuthorizationSettingsView: View {
    @Environment(ApplicationSession.self) private var application
    @Environment(LoginSession.self) private var login
    @State private var pairingSource: DevicePairingSource?
    #if os(macOS)
    @State private var importingImage = false
    @State private var importError: String?
    #endif

    var body: some View {
        let identity = application.identity
        let canAuthorize = identity.canEnroll && !identity.savedScopes.isEmpty
        Form {
            if application.networkClock.status != .ready { NetworkClockNotice(clock: application.networkClock) }
            if login.session == nil {
                SavedAccountIdentitySection(identity: identity, showsPicker: true)
            }
            Section {
                Button {
                    guard application.networkClock.isReadyNow() else { return }
                    ClientLog.shared.record(.identity, "scanPairingCode")
                    pairingSource = .camera
                } label: {
                    SettingsRow(title: "扫描授权二维码", subtitle: "使用摄像头扫描新设备", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("scan-device-pairing-qr")
                Button {
                    guard application.networkClock.isReadyNow() else { return }
                    ClientLog.shared.record(.identity, "importPairingImage")
                    #if os(iOS)
                    pairingSource = .photoLibrary
                    #else
                    importingImage = true
                    #endif
                } label: {
                    #if os(iOS)
                    let subtitle: LocalizedMessage = "从照片图库选择一张图片"
                    #else
                    let subtitle: LocalizedMessage = "选择此设备上的图片"
                    #endif
                    SettingsRow(title: "导入二维码图片", subtitle: subtitle, systemImage: "photo")
                }
                .accessibilityIdentifier("import-device-pairing-image")
            } footer: {
                if canAuthorize {
                    MessageText("仅批准您本人持有的新设备。图片在本机识别，不上传服务器；导入图片必须核对新设备当前显示的安全码。")
                } else {
                    MessageText("此设备没有授权新设备的权限。")
                }
            }
            .buttonStyle(.plain)
            .disabled(!canAuthorize || application.networkClock.status != .ready)
            #if os(macOS)
            if let importError { Section { SettingsFailure(message: importError) } }
            #endif
        }
        .formStyle(.grouped).chirpForm()
        .onChange(of: application.networkClock.status == .ready) {
            guard application.networkClock.status != .ready else { return }
            pairingSource = nil
            #if os(macOS)
            importingImage = false
            #endif
        }
        .sheet(item: $pairingSource) { source in
            DevicePairingFlowView(source: source)
        }
        #if os(macOS)
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                guard application.networkClock.isReadyNow() else { return }
                importError = nil
                pairingSource = .imageFile(url)
            case .failure(let error):
                if (error as NSError).code != CocoaError.userCancelled.rawValue {
                    importError = error.localizedDescription
                }
            }
        }
        #endif
    }
}
