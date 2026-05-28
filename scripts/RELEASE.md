# Releasing System Load

Auto-updates are delivered with [Sparkle](https://sparkle-project.org). The feed
lives at `appcast.xml` in this repo and is served to the app from
`https://raw.githubusercontent.com/kyzdes/system-load/main/appcast.xml`. Release
artifacts (ZIP + DMG) are attached to GitHub Releases on `kyzdes/system-load`.

## One-time setup

1. **Developer ID cert** — "Developer ID Application: Viacheslav Kuznetsov (XDQ47DMXMK)" in the login Keychain.
2. **Notarization profile** — reuses the existing `CCUsageViewer` profile. A notary
   profile is just stored Apple-account credentials (notarization is per developer
   account, not per app), so one profile works for every app. Only if it's missing:
   ```sh
   xcrun notarytool store-credentials "CCUsageViewer" \
     --apple-id "kyzdes5@gmail.com" --team-id "XDQ47DMXMK" \
     --password "<app-specific-password>"   # from account.apple.com → App-Specific Passwords
   ```
3. **Sparkle EdDSA key** (already generated):
   ```sh
   generate_keys --account SystemLoad   # private key stays in the Keychain; never committed
   ```
   The matching public key is in the Info.plist (`SUPublicEDKey`, via `project.yml`).
4. Tools: `brew install xcodegen create-dmg` (xmllint + gh come with macOS / `brew install gh`).

## Per release

1. **Bump the version** in `project.yml`:
   - `MARKETING_VERSION` — semver, user-facing (e.g. `1.0.1`).
   - `CURRENT_PROJECT_VERSION` — build number, **increment every release** (Sparkle compares this).
2. **Build, sign, notarize, package:**
   ```sh
   ./scripts/release.sh
   ```
   Produces a notarized + stapled `build/release/SystemLoad.zip` and `SystemLoad.dmg`
   and prints the Sparkle-signed appcast `<item>`.
3. **Publish** (GitHub Release + appcast + tag + verify):
   ```sh
   ./scripts/publish.sh <version> [--notes-file notes.html]   # try --dry-run first
   ```
   `notes.html` is a list of `<li>` bullets for the release notes / appcast description.

## Notes

- **Update testing needs a *newer* build.** With `vX` published, bump to `vX+1`
  (or temporarily lower the running app's version) so Sparkle sees an update,
  then use *Check for Updates…* and confirm it downloads, validates the EdDSA
  signature, and installs without Gatekeeper warnings.
- `raw.githubusercontent.com` caches the feed ~5 minutes — `publish.sh`'s verify
  step warns rather than fails if the live top item lags.
- The app icon is reproducible via `./scripts/make-icon.sh`.
