import Foundation
import Security

enum SavedConnection {
    // Development data is discarded, not migrated. No room secret is imported
    // or restored; new MLS identities and group state live only in memory.
    static func discardRetiredRoomKeys() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "cn.youzifeile.chirp"] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "keyID")
    }
}
