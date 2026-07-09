# Honeycrisp 2

A native macOS SwiftUI menu bar remote for Apple TV, built on a pure-Swift
implementation of Apple's "Companion" protocol (`CompanionKit`) — no
third-party pairing/streaming libraries, no Xcode project.

## Acknowledgments

`CompanionKit` is a Swift port of the Apple TV "Companion" protocol as
reverse-engineered and implemented in [pyatv](https://github.com/postlund/pyatv)
by Pierre Ståhl — the pairing, encryption, and discovery logic follows pyatv, and
its test vectors were carried over to validate wire compatibility. SRP math uses
[attaswift/BigInt](https://github.com/attaswift/BigInt). Both are MIT-licensed;
see [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

## License

MIT — see [LICENSE](LICENSE).

## Development

```sh
swift test          # run the CompanionKit test suite
Scripts/make-app.sh  # build a release binary and assemble dist/Honeycrisp.app
```
