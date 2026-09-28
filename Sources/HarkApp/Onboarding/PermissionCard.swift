import SwiftUI

/// One permission: what it is for, where it stands, and the button that moves it on.
struct PermissionCard: View {
    enum State: Equatable {
        case granted
        case denied
        case pending
        case checking
        case unknown(OSStatus)
    }

    let symbol: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let state: State
    var isOptional = false
    var isRequired = false
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.headline)
                    if isOptional {
                        badge(L("onboarding.optional"))
                    } else if isRequired {
                        badge(L("onboarding.required"))
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 8)
                    actions
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func badge(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .granted:
            Label {
                Text(L("onboarding.status.granted"))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .denied:
            Label {
                Text(L("onboarding.status.denied"))
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        case .pending:
            Label {
                Text(L("onboarding.status.pending"))
            } icon: {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("onboarding.status.checking"))
            }
        case .unknown(let status):
            let code = Int(status)
            Label {
                Text(L("onboarding.status.unknown \(code)"))
            } icon: {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            }
        }
    }

    /// Only the transitions the state allows: nothing once granted, System Settings once denied.
    @ViewBuilder private var actions: some View {
        switch state {
        case .granted, .checking:
            EmptyView()
        case .denied:
            Button(action: openSettings) { Text(L("permission.openSystemSettings")) }
        case .pending, .unknown:
            Button(action: openSettings) { Text(L("permission.openSystemSettings")) }
                .buttonStyle(.link)
            Button(action: request) { Text(L("onboarding.allow")) }
                .buttonStyle(.borderedProminent)
        }
    }
}
