# Honeycrisp 2

A native macOS SwiftUI menu bar remote for Apple TV, built on a pure-Swift
implementation of Apple's "Companion" protocol (`CompanionKit`) — no
third-party pairing/streaming libraries, no Xcode project.

## Development

```sh
swift test          # run the CompanionKit test suite
Scripts/make-app.sh  # build a release binary and assemble dist/Honeycrisp.app
```
