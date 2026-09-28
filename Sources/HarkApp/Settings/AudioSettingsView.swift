import HarkCore
import SwiftUI

/// The input picker. Always-on, which would add its controls to this tab, is set aside (docs/ROADMAP.md).
struct AudioSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Picker(selection: selection) {
                    Text(systemDefault).tag(String?.none)
                    ForEach(model.inputDevices) { device in
                        Text(verbatim: device.name).tag(String?.some(device.uid))
                    }
                    if let uid = model.preferences.inputDeviceUID,
                        !model.inputDevices.contains(where: { $0.uid == uid })
                    {
                        Text(L("settings.audio.input.unavailable")).tag(String?.some(uid))
                    }
                } label: {
                    Text(L("settings.audio.input"))
                }

                if model.inputChoice?.warning == .preferredDeviceMissing, let fallback = model.inputChoice?.device {
                    Label {
                        Text(L("settings.audio.input.missing \(fallback.name)"))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }

                Text(L("settings.audio.input.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("settings.audio.section"))
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshInputDevices() }
    }

    private var selection: Binding<String?> {
        Binding(get: { model.preferences.inputDeviceUID }, set: { model.preferences.inputDeviceUID = $0 })
    }

    private var systemDefault: AttributedString {
        guard let device = model.systemDefaultInput else {
            return AttributedString(localized: L("settings.audio.input.systemDefault"))
        }
        return AttributedString(localized: L("settings.audio.input.systemDefaultNamed \(device.name)"))
    }
}
