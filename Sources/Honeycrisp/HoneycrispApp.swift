import AppKit
import SwiftUI

@main
@MainActor
struct HoneycrispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // The remote itself: fixed 200x500, no title bar, draggable by background.
        // First scene, so SwiftUI opens it at launch — its `.task` is what hands
        // the app delegate (which owns the status item) `openWindow` and state.
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
                .task {
                    appDelegate.appState = appState
                    appDelegate.openWindow = openWindow
                }
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

/// Bring the remote window to the front, activating the app first.
///
/// A menu-bar-extra click does not make the app active, and macOS won't front a
/// window belonging to an inactive app — so `openWindow` alone leaves an
/// already-open-but-occluded remote hidden. Activate, open (creates/reopens if
/// it was closed), then explicitly order the existing window front to cover the
/// occluded/minimized case.
@MainActor
func showRemote(_ openWindow: OpenWindowAction) {
    // `ignoringOtherApps: true` (deprecated but not replaced by an equally
    // forceful API): plain `activate()` only foregrounds when the system
    // permits, which made "Show Remote" work only sometimes — the window would
    // order-front behind another app that never yielded activation.
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: WindowID.remote)
    if let window = NSApp.windows.first(where: {
        $0.identifier?.rawValue == WindowID.remote
    }) {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App delegate

/// Owns the menu-bar status item, and brings the remote back when the app is
/// activated with nothing on screen.
///
/// The status item is AppKit rather than a SwiftUI `MenuBarExtra` because
/// `MenuBarExtra` cannot tell clicks apart: here a left click shows the remote
/// and a right (or control) click opens the menu.
///
/// With `LSUIElement` false the app lives in the Cmd-Tab switcher; switching to
/// it only *activates* the app (no reopen event), so if every window was closed
/// nothing would appear. Dock-icon clicks send `applicationShouldHandleReopen`
/// instead. Both paths reopen the remote window when no regular window exists.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wired up by `HoneycrispApp` once the remote window first appears.
    var appState: AppState?
    var openWindow: OpenWindowAction?

    private var statusItem: NSStatusItem?

    /// Opens the remote Window scene (idempotent: opening an already-open
    /// `Window` fronts it).
    private func openRemote() {
        guard let openWindow else { return }
        showRemote(openWindow)
    }

    /// `true` when some user-facing window is open or minimized. The menu bar
    /// extra's status item is backed by an always-visible window, so filter to
    /// windows that can become key.
    private var hasUserWindow: Bool {
        NSApp.windows.contains { $0.canBecomeKey && ($0.isVisible || $0.isMiniaturized) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "appletvremote.gen4.fill", accessibilityDescription: "Honeycrisp")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !hasUserWindow { openRemote() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !hasUserWindow { openRemote() }
    }

    // MARK: Status item

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else {
            openRemote()
            return
        }
        // Attach the menu just for this click: while `menu` is set, AppKit
        // opens it on every click and the action above never fires.
        statusItem?.menu = makeMenu()
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Built fresh on each right click so the device list is current.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Show Remote", #selector(showRemoteClicked)))
        menu.addItem(.separator())

        let devices = appState?.devices ?? []
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            // Radio-style device picker: checkmark marks the active device.
            for device in devices {
                let item = menuItem(device.name, #selector(deviceClicked(_:)))
                item.representedObject = device.id
                item.state = device.id == appState?.activeDeviceID ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Add Device…", #selector(addDeviceClicked)))
        menu.addItem(menuItem("Manage Devices…", #selector(manageDevicesClicked)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showRemoteClicked() { openRemote() }

    @objc private func deviceClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        appState?.setActiveDevice(id)
    }

    @objc private func addDeviceClicked() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: WindowID.addDevice)
    }

    @objc private func manageDevicesClicked() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: WindowID.manageDevices)
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
///
/// The window is made fully borderless: with `.titled` present, the theme frame
/// draws its own rounded-corner rim (white slivers around the body's radius-24
/// shape on macOS 26) and reserves title-bar height (dead space at the bottom).
/// Removing `.titled` fixes both — verified visually — but AppKit then refuses
/// key status (`canBecomeKey == false`), which would kill every keyboard
/// shortcut, so `KeyableWindowSupport` restores it first.
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
        // Tag the window so `showRemote` can locate it in NSApp.windows to
        // order it front when it's already open but occluded/minimized.
        window.identifier = NSUserInterfaceItemIdentifier(WindowID.remote)
        // The window keeps `.titled` (borderless windows lose keyboard focus in
        // SwiftUI even with canBecomeKey patched); the title bar is fully
        // transparent and the container-background material paints under it.
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
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
}
