# Honeycrisp 2

A native macOS SwiftUI menu bar remote for Apple TV, built on a pure-Swift
implementation of Apple's "Companion" protocol (`CompanionKit`) — no
third-party pairing/streaming libraries, no Xcode project.

## Development

```sh
swift test --filter HoneycrispTests                 # fast app-layer tests
swift test -c release --filter CompanionKitTests    # protocol tests (use -c release: debug is ~5 min due to BigInt)
Scripts/make-app.sh                                 # ad-hoc dev build -> dist/Honeycrisp.app
```

## Releasing

A prod release is a Developer ID–signed, notarized, universal (arm64 + x86_64)
build published as a GitHub Release.

### One-time setup

1. **Developer ID Application certificate** in your login keychain — Xcode →
   Settings → Accounts → your team → Manage Certificates → **+** → *Developer ID
   Application*. Verify with `security find-identity -v -p codesigning`.
2. **Notary profile** — generate an app-specific password at appleid.apple.com,
   then:
   ```sh
   xcrun notarytool store-credentials honeycrisp-notary \
     --apple-id <apple-id> --team-id A23QBHEP27 --password <app-specific-password>
   ```
   (If this 403s with "a required agreement is missing or has expired," the
   account holder must accept the updated Program License Agreement at
   developer.apple.com/account first, then wait a few minutes.)

### Cut a release

```sh
# 1. Build: sign (hardened runtime) -> notarize -> staple -> Gatekeeper-check -> zip
VERSION=0.1.0 Scripts/make-app.sh --release

# 2. Tag the release commit and publish with the notarized zip
git tag v0.1.0 && git push origin v0.1.0
gh release create v0.1.0 dist/Honeycrisp-0.1.0.zip \
  --repo dickfickling/honeycrisp \
  --title "Honeycrisp 0.1.0" --notes "..."
```

`make-app.sh --release` honors `VERSION`, `SIGN_IDENTITY` (default
`Developer ID Application`), and `NOTARY_PROFILE` (default `honeycrisp-notary`).
Set `SKIP_NOTARIZE=1` to test the signing pipeline without a notarization
round-trip.
