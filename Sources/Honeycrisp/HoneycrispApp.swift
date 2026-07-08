import AppKit
import SwiftUI

@main
@MainActor
struct HoneycrispApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        // Tray menu.
        MenuBarExtra("Honeycrisp", systemImage: "appletvremote.gen4.fill") {
            TrayMenu()
                .environment(appState)
        }

        // The remote itself: fixed 200x500, no title bar, draggable by background.
        Window("Remote", id: WindowID.remote) {
            RemoteView()
                .environment(appState)
                .background(RemoteWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 200, height: 500)

        // Placeholder for the (future) pairing flow.
        Window("Add Device", id: WindowID.addDevice) {
            AddDeviceView()
                .environment(appState)
        }
        .windowResizability(.contentSize)

        // Simple list with delete.
        Window("Manage Devices", id: WindowID.manageDevices) {
            ManageDevicesView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let remote = "remote"
    static let addDevice = "addDevice"
    static let manageDevices = "manageDevices"
}

// MARK: - Tray menu

private struct TrayMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Remote") { openWindow(id: WindowID.remote) }

        Divider()

        if appState.devices.isEmpty {
            Text("No devices")
        } else {
            // Radio-style device picker: checkmark marks the active device.
            ForEach(appState.devices) { device in
                Button {
                    appState.setActiveDevice(device.id)
                } label: {
                    if device.id == appState.activeDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        }

        Divider()

        Button("Add Device…") { openWindow(id: WindowID.addDevice) }
        Button("Manage Devices…") { openWindow(id: WindowID.manageDevices) }

        Divider()

        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Add Device (placeholder)

private struct AddDeviceView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "appletvremote.gen4")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Add a device")
                .font(.headline)
            Text("Pairing with an Apple TV will be available in a later update.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 320, height: 220)
    }
}

// MARK: - Manage Devices

private struct ManageDevicesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Manage Devices")
                .font(.headline)
                .padding()

            Divider()

            if appState.devices.isEmpty {
                Text("No devices")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(appState.devices) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Button(role: .destructive) {
                                appState.removeDevice(device.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .frame(width: 280, height: 360)
    }
}

// MARK: - Window configuration

/// Configures the remote's `NSWindow` so it is transparent (letting the rounded
/// body show through), draggable by its background, and free of a title bar.
private struct RemoteWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
