import SwiftUI

// MARK: - Palette

private enum Palette {
    /// Remote body background, gray ~ rgb(156,163,175) (Tailwind gray-400).
    static let body = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)
    /// Control fill, near-black dark navy ~ #0D1526.
    static let control = Color(red: 0x0D / 255, green: 0x15 / 255, blue: 0x26 / 255)
    /// Header text / power outline, gray ~ rgb(75,85,99) (Tailwind gray-600).
    static let subtle = Color(red: 75 / 255, green: 85 / 255, blue: 99 / 255)
    /// Thin marker outline inside the d-pad.
    static let innerOutline = Color.white.opacity(0.35)
}

/// Press feedback shared by every control: a subtle scale + fade while held.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Remote

/// The frameless 200x500 remote. Every control fires a `RemoteCommand` through
/// `AppState`; keyboard shortcuts mirror the button layout while the window is key.
struct RemoteView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 12)
            DPad { appState.send($0) }
                .frame(width: 160, height: 160)

            Spacer(minLength: 12)
            HStack(spacing: 8) {
                CircleControl(systemImage: "chevron.left", size: 80) { appState.send(.menu) }
                CircleControl(systemImage: "tv", size: 80) { appState.send(.homeHold) }
            }

            Spacer(minLength: 12)
            HStack(alignment: .top, spacing: 8) {
                CircleControl(systemImage: "playpause", size: 80) { appState.send(.playPause) }
                VolumeRocker(
                    onUp: { appState.send(.volumeUp) },
                    onDown: { appState.send(.volumeDown) }
                )
                .frame(width: 80)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(width: 200, height: 500)
        .background(Palette.body)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.activeDevice?.name ?? "No device")
                    .font(.caption)
                    .foregroundStyle(Palette.subtle)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.subtle)
                }
            }
            .help(appState.remote?.lastError ?? statusText)
            Spacer()
            Button { appState.send(.powerToggle) } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.subtle)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(Palette.subtle, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private var connectionState: ConnectionState {
        appState.remote?.connectionState ?? .disconnected
    }

    private var statusColor: Color {
        switch connectionState {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return Palette.subtle.opacity(0.6)
        }
    }

    private var statusText: String {
        guard appState.activeDevice != nil else { return "No device" }
        switch connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let command: RemoteCommand?
        switch press.key {
        case .upArrow: command = .up
        case .downArrow: command = .down
        case .leftArrow: command = .left
        case .rightArrow: command = .right
        case .return: command = .select
        case .space: command = .select
        case .delete: command = .menu // Backspace
        default:
            switch press.characters {
            case "h": command = .homeHold
            case "[": command = .volumeDown
            case "]": command = .volumeUp
            default: command = nil
            }
        }
        guard let command else { return .ignored }
        appState.send(command)
        return .handled
    }
}

// MARK: - D-pad

/// Large navy circle with N/S/E/W dot buttons and a center select zone marked by
/// a thin inner outline (~55% diameter).
private struct DPad: View {
    let send: (RemoteCommand) -> Void

    private let edge: CGFloat = 60

    var body: some View {
        ZStack {
            Circle().fill(Palette.control)

            // Directional tap zones, pinned to each edge; the dot sits at the rim.
            directionButton(.up, alignment: .top)
            directionButton(.down, alignment: .bottom)
            directionButton(.left, alignment: .leading)
            directionButton(.right, alignment: .trailing)

            // Center select zone.
            Button { send(.select) } label: {
                Circle()
                    .stroke(Palette.innerOutline, lineWidth: 1)
                    .frame(width: 88, height: 88)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())
        }
        .clipShape(Circle())
    }

    private func directionButton(_ command: RemoteCommand, alignment: Alignment) -> some View {
        Button { send(command) } label: {
            ZStack { dot(for: alignment) }
                .frame(width: edge, height: edge)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// Positions the white dot toward the outer rim for the given edge.
    private func dot(for alignment: Alignment) -> some View {
        let inset: CGFloat = 8
        var offset = CGSize.zero
        switch alignment {
        case .top: offset = CGSize(width: 0, height: -inset)
        case .bottom: offset = CGSize(width: 0, height: inset)
        case .leading: offset = CGSize(width: -inset, height: 0)
        case .trailing: offset = CGSize(width: inset, height: 0)
        default: break
        }
        return Circle()
            .fill(Color.white)
            .frame(width: 5, height: 5)
            .offset(offset)
    }
}

// MARK: - Circular icon control

private struct CircleControl: View {
    let systemImage: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Palette.control)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Volume rocker

/// Vertical capsule: top half is volume up ("+"), bottom half is volume down ("−").
private struct VolumeRocker: View {
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        ZStack {
            Capsule().fill(Palette.control)
            VStack(spacing: 0) {
                rockerButton(systemImage: "plus", action: onUp)
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.horizontal, 18)
                rockerButton(systemImage: "minus", action: onDown)
            }
        }
        .clipShape(Capsule())
    }

    private func rockerButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}
