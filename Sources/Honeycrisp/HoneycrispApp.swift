import AppKit
import SwiftUI

@main
@MainActor
struct HoneycrispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Tray menu. The label view is hosted in the status bar for the app's
        // whole lifetime, so it doubles as the place where the app delegate is
        // wired up with an `openWindow` it can call on Cmd-Tab reactivation.
        MenuBarExtra {
            TrayMenu()
                .environment(appState)
        } label: {
            Label("Honeycrisp", systemImage: "appletvremote.gen4.fill")
                .task { appDelegate.openRemote = { openWindow(id: WindowID.remote) } }
        }

        // The remote itself: fixed 200x500, no title bar, draggable by background.
        Window("Remote", id: WindowID.remote) {
            RemoteView()
                .environment(appState)
                .background(RemoteWindowConfigurator())
                // Fill the whole (title-bar-free) content area so the remote
                // body's rounded rectangle alone defines the window shape.
                .ignoresSafeArea()
                // On macOS 26 a liquid-glass toolbar strip is auto-created for
                // hidden-title-bar windows; keep it and its background out.
                .toolbar(.hidden, for: .windowToolbar)
                .hiddenWindowToolbarBackground()
                // macOS 26 paints an opaque container background (the white
                // sheet visible at the corners) over the whole window frame
                // regardless of NSWindow.backgroundColor; clear it so only the
                // remote body's rounded rectangle is visible.
                .clearWindowContainerBackground()
                // Belt-and-braces: also wire the delegate from here in case a
                // menu-bar style ever stops hosting the label eagerly.
                .task { appDelegate.openRemote = { openWindow(id: WindowID.remote) } }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 200, height: 500)

        // Pairing wizard: scan → PIN → save.
        Window("Add Device", id: WindowID.addDevice) {
            PairingView()
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

// MARK: - App delegate

/// Brings the remote back when the app is activated with nothing on screen.
///
/// With `LSUIElement` false the app lives in the Cmd-Tab switcher; switching to
/// it only *activates* the app (no reopen event), so if every window was closed
/// nothing would appear. Dock-icon clicks send `applicationShouldHandleReopen`
/// instead. Both paths reopen the remote window when no regular window exists.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the remote Window scene; wired up by `HoneycrispApp` via
    /// `openWindow` (idempotent: opening an already-open `Window` fronts it).
    var openRemote: (() -> Void)?

    /// `true` when some user-facing window is open or minimized. The menu bar
    /// extra's status item is backed by an always-visible window, so filter to
    /// windows that can become key.
    private var hasUserWindow: Bool {
        NSApp.windows.contains { $0.canBecomeKey && ($0.isVisible || $0.isMiniaturized) }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !hasUserWindow { openRemote?() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !hasUserWindow { openRemote?() }
    }
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
        // The async configuration can land after SwiftUI already sized the
        // window with a title-bar inset (content 500 + ~28pt of dead space at
        // the bottom); re-assert the intended content size now that the
        // content view spans the full frame.
        window.setContentSize(NSSize(width: 200, height: 500))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarSeparatorStyle = .none
        // macOS 26 auto-creates a liquid-glass NSToolbar for hidden-title-bar
        // windows, rendering a glass strip over the remote; drop it entirely.
        window.toolbar = nil
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

/// `toolbarBackgroundVisibility(_:for:)` is macOS 15+; the package still
/// targets macOS 14, so apply it behind an availability check.
extension View {
    @ViewBuilder
    fileprivate func hiddenWindowToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }

    /// `containerBackground(_:for: .window)` is macOS 15+; the package still
    /// targets macOS 14, so apply it behind an availability check.
    @ViewBuilder
    fileprivate func clearWindowContainerBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(.clear, for: .window)
        } else {
            self
        }
    }
}
