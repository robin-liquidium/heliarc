# Releasing Heliarc

Use `$heliarc-release` from this repository. `release.json` is the source of truth for the version, integer build, date, and release notes. `python3 script/prepare_release.py` validates it and synchronizes the README.

Every public release is a universal macOS 14+ application, signed with Developer ID, notarized by Apple, stapled, and distributed as both a ZIP and DMG. Heliarc has no browser extension or updater framework.

## Credentials

GitHub Actions requires five repository secrets:

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_KEY_P8_BASE64`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

The release workflow loads them into an ephemeral keychain and removes the temporary files even if a run fails. Never commit credentials. For a local release, set `SIGNING_IDENTITY` and either `NOTARY_PROFILE`, or `NOTARY_KEY_PATH`, `APP_STORE_CONNECT_KEY_ID`, and `APP_STORE_CONNECT_ISSUER_ID`.

## Release procedure

1. Inspect the diff since the latest release and update `release.json`. Use a patch version for fixes, a minor version for features, and keep `build` strictly increasing.
2. Run `python3 script/prepare_release.py`, `swift test`, and `python3 script/package_app.py`. Verify the universal architectures, version, entitlements, signature, and included resources.
3. Commit and push `main`, wait for Checks on that exact commit, then create and push one immutable `vVERSION` tag.
4. The Release workflow creates a draft, submits the exact signed app and DMG to Apple, and stores hashes plus submission IDs in `release-state.json`. Scheduled runs resume the same draft while notarization is pending.
5. Once Apple accepts both submissions, the workflow staples and verifies them, uploads stable and versioned ZIP/DMG files plus checksums and evidence, removes temporary submissions, and publishes the release.
6. Download the public assets into a fresh temporary directory. Verify `SHA256SUMS`, the app and DMG staples, Gatekeeper, both architectures, version/build metadata, and the stable latest-release URLs in the README.

The final assets are `Heliarc-VERSION.dmg`, `Heliarc.dmg`, `Heliarc-VERSION.zip`, `Heliarc.zip`, `release.json`, `notarization.json`, `release-state.json`, and `SHA256SUMS`.

## Pending or interrupted notarization

`app_pending` and `dmg_pending` mean Apple is reviewing an already-uploaded artifact. Continue the same draft and submission ID. Never resubmit because Apple is slow.

`*_submitting` means the response may have been lost. Inspect Apple notarization history, reconcile the artifact name and timestamp, save the recovered submission ID into the existing draft state, and move the phase to `*_pending`. Do not submit again unless Apple history proves no request exists.

`*_rejected` requires reading the matching notarization log and fixing the stated issue. A source change requires a new version, build, commit, and tag. Published tags are immutable.

