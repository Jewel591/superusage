import Foundation

struct SyncDeviceIdentity {
    private static let defaultsKey = "superusage.sync.deviceID.v1"

    let id: String
    let persistenceWarning: String?

    init(
        defaults: UserDefaults = .standard,
        store: any ICloudDeviceIDStoring = KeychainICloudDeviceIDStore()
    ) {
        let saved = Self.normalized(defaults.string(forKey: Self.defaultsKey))
        do {
            if let stored = Self.normalized(try store.readDeviceID()) {
                id = stored
                persistenceWarning = nil
                defaults.set(stored, forKey: Self.defaultsKey)
                return
            }

            let generated = saved ?? UUID().uuidString.lowercased()
            try store.writeDeviceID(generated)
            id = generated
            persistenceWarning = nil
            defaults.set(generated, forKey: Self.defaultsKey)
        } catch {
            let generated = saved ?? UUID().uuidString.lowercased()
            id = generated
            persistenceWarning = "superUsage couldn’t persist this Mac’s sync identity in Keychain."
            defaults.set(generated, forKey: Self.defaultsKey)
            AppLog.warn(.keychain, "Sync device identity failed: \(error.localizedDescription)")
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }
}
