import Foundation

enum JevSharedGroup {
    static let originalID = "group.com.jevchat.jarvis.ios"

    /// iLoader 2.3.4 creates group.<signed host bundle ID> for the app and
    /// every extension. Its keyboard ID is <signed host bundle ID>.keyboard.
    static func candidates(bundleID: String?, isKeyboard: Bool) -> [String] {
        guard var hostID = bundleID, !hostID.isEmpty else { return [originalID] }
        if isKeyboard {
            guard hostID.hasSuffix(".keyboard") else { return [originalID] }
            hostID = String(hostID.dropLast(".keyboard".count))
        }
        let signedID = "group." + hostID
        return signedID == originalID ? [originalID] : [signedID, originalID]
    }

    /// A suite being non-nil does NOT prove entitlement to an App Group.
    static func resolve(_ candidates: [String], accessible: (String) -> Bool) -> String? {
        candidates.first(where: accessible)
    }
}
