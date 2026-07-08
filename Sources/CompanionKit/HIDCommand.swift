import Foundation

/// HID command constants sent in a Companion `_hidC` message.
///
/// Byte-exact port of pyatv's `HidCommand` enum (`companion/api.py`); the raw
/// value is what goes on the wire as the `_hidC` field.
public enum HIDCommand: Int, Sendable, CaseIterable {
    case up = 1
    case down = 2
    case left = 3
    case right = 4
    case menu = 5
    case select = 6
    case home = 7
    case volumeUp = 8
    case volumeDown = 9
    case siri = 10
    case screensaver = 11
    case sleep = 12
    case wake = 13
    case playPause = 14
    case channelIncrement = 15
    case channelDecrement = 16
    case guide = 17
    case pageUp = 18
    case pageDown = 19
}

/// The kind of button press to synthesize from HID down/up events.
///
/// Port of pyatv's `InputAction` (`const.py`); the raw value matches pyatv's
/// so it can be surfaced or persisted identically.
public enum InputAction: Int, Sendable, CaseIterable {
    /// Press and release quickly (one down + one up).
    case singleTap = 0
    /// Press and release twice quickly.
    case doubleTap = 1
    /// Press and hold for ~one second before releasing.
    case hold = 2
}
