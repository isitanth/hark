import Foundation

/// The frontmost app from the workspace, its focused element from the Accessibility API, and whether keystrokes are
/// private right now. Runs while the user is still speaking: `triggerDown` starts capture first and this separately.
public struct AXFocusProbe: FocusProbing {
    private let workspace: any Workspace
    private let accessibility: any AccessibilityFacade

    public init(workspace: any Workspace, accessibility: any AccessibilityFacade) {
        self.workspace = workspace
        self.accessibility = accessibility
    }

    public func probe() async -> FocusSnapshot {
        async let secureInput = accessibility.isSecureInputEnabled()
        guard let app = await workspace.frontmostApplication() else {
            return FocusSnapshot(app: nil, isSecureInput: await secureInput)
        }
        let element = await accessibility.focusedElement(of: app.processID)
        // A password field in a web page sets the subrole without taking secure event input, and secure event input
        // held by another app (Terminal's Secure Keyboard Entry) says nothing about the element.
        let secure = await secureInput || element?.subrole == FocusedElement.secureTextFieldSubrole
        return FocusSnapshot(app: app, element: element, isSecureInput: secure)
    }
}
