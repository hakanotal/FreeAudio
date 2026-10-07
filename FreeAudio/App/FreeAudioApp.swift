import SwiftUI

@main
struct FreeAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            // Launch-time work lives in AppDelegate: this content is built lazily and its
            // .task/.onAppear run again every time the panel opens.
            MenuBarView()
        } label: {
            // An equalizer, like the app icon (volume rows keep their speaker symbols).
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
        // Let the panel shrink back when sections collapse (min-only sizing never shrinks).
        .windowResizability(.contentSize)
    }
}
