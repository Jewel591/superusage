import SwiftUI

struct AppleDeviceSyncSettingsSection: View {
    @Bindable var sync: AppleDeviceSyncStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Apple Devices")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Text("Sync to iPhone and Watch")
                    if sync.enabled, sync.isSyncing, sync.serviceError == nil {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Publishing Apple device snapshot")
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $sync.enabled)
                        .settingsSwitchStyle()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, density.controlRowPadding)

                Text("Publishes normalized usage through your private iCloud account. Credentials and raw logs stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if sync.enabled {
                    Divider()
                    if let error = sync.serviceError {
                        notice(error)
                    } else if let date = sync.lastPublishedAt {
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text("Last published \(date.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if !sync.isSyncing {
                        notice("Waiting for the first Mac snapshot…", warning: false)
                    }
                }
            }
            .cardSurface()
        }
    }

    private func notice(_ text: String, warning: Bool = true) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(warning ? AnyShapeStyle(Theme.notice) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
