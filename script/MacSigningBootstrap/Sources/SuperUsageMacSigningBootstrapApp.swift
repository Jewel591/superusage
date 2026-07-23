import CloudKit
import SwiftUI

@main
struct SuperUsageMacSigningBootstrapApp: App {
    @State private var status = "Checking CloudKit…"

    var body: some Scene {
        WindowGroup {
            Text(status)
                .padding()
                .task { await probeCloudKit() }
        }
    }

    @MainActor
    private func probeCloudKit() async {
        do {
            let container = CKContainer(identifier: "iCloud.com.weisenjoytech.usage.sync")
            let accountStatus = try await container.accountStatus()
            let zone = CKRecordZone(zoneName: "SuperUsageSigningProbe")
            _ = try await container.privateCloudDatabase.save(zone)
            status = "CloudKit ready (account status: \(accountStatus.rawValue))."
            print("SUPERUSAGE_CLOUDKIT_PROBE_OK accountStatus=\(accountStatus.rawValue)")
        } catch {
            let nsError = error as NSError
            status = "CloudKit probe failed: \(error.localizedDescription)"
            print(
                "SUPERUSAGE_CLOUDKIT_PROBE_FAILED domain=\(nsError.domain) "
                    + "code=\(nsError.code) userInfo=\(nsError.userInfo)"
            )
        }
    }
}
