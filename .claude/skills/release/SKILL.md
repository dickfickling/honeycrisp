---
name: release
description: Cut a notarized Honeycrisp prod release — Developer ID sign, notarize, staple, and publish a universal build as a GitHub Release. Use when asked to ship/publish/cut a release or push a new version.
---

# Release Honeycrisp

Build a Developer ID–signed, notarized, universal (arm64 + x86_64) `.app`, then
publish it as a GitHub Release on `dickfickling/honeycrisp`.

## Arguments

The version string, e.g. `0.2.0`. If none is given, ask for it (do not guess or
reuse the last one).

## Steps

1. **Verify prerequisites** — bail early with the fix if either is missing:
   - Developer ID cert: `security find-identity -v -p codesigning | grep "Developer ID Application"`.
     Missing → Xcode → Settings → Accounts → team → Manage Certificates → **+** →
     *Developer ID Application*.
   - Notary profile: `xcrun notarytool history --keychain-profile honeycrisp-notary`
     should succeed. Missing/erroring → `xcrun notarytool store-credentials
     honeycrisp-notary --apple-id <apple-id> --team-id A23QBHEP27 --password
     <app-specific-password>`. A 403 "required agreement is missing or has
     expired" means the account holder must accept the updated Program License
     Agreement at developer.apple.com/account, then wait a few minutes.
   - `gh auth status` shows logged in.

2. **Clean working tree** — `git status` should be clean and on `main`. The
   release is tagged at the current `HEAD`; confirm that is the commit to ship.

3. **Build + notarize** (runs sign → notarize round-trip → staple → Gatekeeper
   check → zip; the notary step takes a few minutes, so run it in the
   background and poll):
   ```sh
   VERSION=<version> Scripts/make-app.sh --release
   ```
   Confirm the output ends with `Upload: dist/Honeycrisp-<version>.zip` and that
   the Gatekeeper check printed `source=Notarized Developer ID`. If notarization
   is rejected, get the log with
   `xcrun notarytool log <submission-id> --keychain-profile honeycrisp-notary`.

4. **Tag and publish**:
   ```sh
   git tag v<version> && git push origin v<version>
   gh release create v<version> dist/Honeycrisp-<version>.zip \
     --repo dickfickling/honeycrisp \
     --title "Honeycrisp <version>" \
     --notes-file <notes>
   ```
   Write brief release notes (what changed since the last tag — check
   `git log <previous-tag>..HEAD`) plus the standard install line: download the
   zip, unzip, drag `Honeycrisp.app` to Applications; it's notarized so it opens
   without Gatekeeper warnings; add a device via the tray menu → Add Device.

5. **Verify** — `gh release view v<version> --repo dickfickling/honeycrisp` shows
   the asset attached and `isDraft: false`. Report the release URL.

## Notes

- `make-app.sh --release` honors `VERSION`, `SIGN_IDENTITY` (default
  `Developer ID Application`), `NOTARY_PROFILE` (default `honeycrisp-notary`),
  and `SKIP_NOTARIZE=1` (sign only, skip the notarize round-trip — for testing
  the pipeline, never for a real release).
- The default (no `--release`) build is ad-hoc signed for local dev only; it is
  not distributable.
