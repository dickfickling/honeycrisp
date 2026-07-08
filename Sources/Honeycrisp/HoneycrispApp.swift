import AppKit
import SwiftUI

@main
@MainActor
struct HoneycrispApp: App {
    var body: some Scene {
        MenuBarExtra("Honeycrisp", systemImage: "appletvremote.gen4.fill") {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Window("Honeycrisp", id: "main") {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        Text("Honeycrisp")
            .padding(40)
    }
}
