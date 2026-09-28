import SwiftUI

extension View {
    /// The one confirmation before the dictation history is deleted, the same from the panel and the Log tab.
    func clearHistoryConfirmation(isPresented: Binding<Bool>, clear: @escaping () -> Void) -> some View {
        confirmationDialog(Text(L("history.clear.title")), isPresented: isPresented, titleVisibility: .visible) {
            Button(role: .destructive, action: clear) {
                Text(L("history.clear.confirm"))
            }
        } message: {
            Text(L("history.clear.message"))
        }
    }
}
