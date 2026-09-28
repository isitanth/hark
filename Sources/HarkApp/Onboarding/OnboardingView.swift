import AppKit
import HarkCore
import SwiftUI

/// Three cards — Microphone and Accessibility, required, and Automation, optional — each with its live status and the one action that moves
/// it forward. Shown once at first launch, and again from Settings › General.
struct OnboardingView: View {
    static let windowID = "onboarding"

    let model: AppModel
    @State private var onboarding = OnboardingModel()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("onboarding.title"))
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("onboarding.subtitle"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionCard(
                symbol: "mic", title: L("onboarding.microphone.title"), detail: L("onboarding.microphone.detail"),
                state: microphoneState, isRequired: true
            ) {
                onboarding.requestMicrophone { model.openPrivacySettings(.microphone) }
            } openSettings: {
                model.openPrivacySettings(.microphone)
            }

            PermissionCard(
                symbol: "accessibility", title: L("onboarding.accessibility.title"),
                detail: L("onboarding.accessibility.detail"), state: onboarding.accessibility ? .granted : .pending,
                isRequired: true
            ) {
                onboarding.requestAccessibility()
            } openSettings: {
                model.openPrivacySettings(.accessibility)
            }

            PermissionCard(
                symbol: "applescript", title: L("onboarding.automation.title"),
                detail: L("onboarding.automation.detail"), state: automationState, isOptional: true
            ) {
                onboarding.requestAutomation()
            } openSettings: {
                model.openPrivacySettings(.automation)
            }

            HStack {
                Spacer()
                Button {
                    dismissWindow(id: Self.windowID)
                } label: {
                    Text(L("onboarding.done"))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            onboarding.startPolling()
            NSApplication.shared.activate()
        }
        .onDisappear {
            onboarding.stopPolling()
            model.finishOnboarding()
            model.refreshPermissions()
        }
    }

    private var microphoneState: PermissionCard.State {
        switch onboarding.microphone {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .pending
        }
    }

    private var automationState: PermissionCard.State {
        if onboarding.isAskingAutomation { return .checking }
        switch onboarding.automation {
        case nil: return .checking
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined, .targetNotRunning: return .pending
        case .unknown(let code): return .unknown(code)
        }
    }
}
