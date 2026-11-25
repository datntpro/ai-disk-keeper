# Releasing AI Disk Keeper

## 1. Overview

```
swift test
  → make-app.sh --config release --universal --output dist   (ad-hoc signed, resources verified)
  → sign-app.sh        (force re-sign: Developer ID + hardened runtime + secure timestamp)
  → zip → notarize.sh  (app) → stapler staple (app)
  → make-dmg.sh        (DMG of the stapled app, signed)
  → notarize.sh (DMG) → stapler staple (DMG)
  → Gatekeeper assessments → GitHub Release
```

The app is notarized *and* the DMG is notarized: stapling the app lets it pass Gatekeeper offline
after it is dragged out of the DMG; stapling the DMG makes the download itself pass.

Credential modes (decided in one preflight step of `.github/workflows/release.yml`):

- **full**: all signing + notary secrets present. Everything above runs.
- **unsigned**: no Apple secrets at all. Signing/notarization are skipped with a `::notice::`; artifacts
  are still built (ad-hoc signed) and a tag run creates a **draft** release labelled UNSIGNED.
- **partial**: some but not all secrets. The run **fails** and lists the missing secret *names*.

## 2. One-time setup (owner)

Apple side:

1. **Apple Developer Program** membership (the paid org or individual account). The Team ID is shown under Membership.
2. A **"Developer ID Application" certificate**.
   - Only the *Account Holder* can create one: in Xcode, Settings → Accounts → Manage Certificates → + → Developer ID Application; or on developer.apple.com, Certificates.
   - Export it **with its private key** from Keychain Access as `.p12` with a strong password.
3. An **App Store Connect API key** for notarization: App Store Connect → Users and Access → Integrations → Team Keys, role **Developer**. Download the `.p8`; it can be downloaded only once. Note the Key ID and the Issuer ID.
   - Alternative (supported, not recommended): an Apple ID + **app-specific password** (appleid.apple.com).

GitHub side: Settings → Environments → create **`release`**. Optionally add a required reviewer. If you restrict its deployment refs, allow both tags `v*` **and** `main`, otherwise `workflow_dispatch` dry runs from `main` are rejected. Then add the secrets **to that environment**:

| Secret | Value | Required |
|---|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` | yes (full mode) |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12 export password | yes |
| `APPLE_TEAM_ID` | the 10-char Team ID | yes |
| `MACOS_SIGNING_IDENTITY` | e.g. `Developer ID Application: <Name> (<TEAMID>)` | optional; auto-detected if the keychain holds exactly one Developer ID Application identity |
| `NOTARY_API_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8` | yes, unless using the Apple ID pair |
| `NOTARY_API_KEY_ID` | Key ID | with the API key |
| `NOTARY_API_ISSUER_ID` | Issuer UUID | with the API key |
| `NOTARY_APPLE_ID` / `NOTARY_APP_PASSWORD` | Apple ID email + app-specific password | alternative to the 3 API-key secrets |

No keychain password secret is needed: a random one is generated per run.

## 3. Cutting a release

1. Bump `DiskKeeperCore.version` in a PR and merge it. The tag must match it (suffixes like `-rc.1` make a prerelease).
2. `git tag -a v0.1.0 -m "v0.1.0" && git push origin v0.1.0`
3. Review the release (a draft if the build was unsigned) and edit the Highlights before publishing.

## 4. Dry run

Actions → Release → Run workflow (`dry_run=true`) on `main`, or push a test tag `v0.0.1-rc.1`
(prerelease) and delete it afterwards: `gh release delete v0.0.1-rc.1 --cleanup-tag`.
A dry run builds, signs and notarizes but creates no release; artifacts are attached to the run.

## 5. Running locally

```sh
export SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
./scripts/make-app.sh --config release --universal --output dist
./scripts/sign-app.sh "dist/AI Disk Keeper.app"
# notarization auth: either NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER, or
# NOTARY_APPLE_ID/NOTARY_APP_PASSWORD/NOTARY_TEAM_ID, or a stored profile:
#   xcrun notarytool store-credentials aidk && export NOTARY_KEYCHAIN_PROFILE=aidk
ditto -c -k --sequesterRsrc --keepParent "dist/AI Disk Keeper.app" dist/app.zip
./scripts/notarize.sh dist/app.zip && xcrun stapler staple "dist/AI Disk Keeper.app"
./scripts/make-dmg.sh "dist/AI Disk Keeper.app" dist/AI-Disk-Keeper.dmg
./scripts/notarize.sh dist/AI-Disk-Keeper.dmg && xcrun stapler staple dist/AI-Disk-Keeper.dmg
```

## 6. Entitlements

`Packaging/AIDiskKeeper.entitlements` is deliberately an **empty dict**. Hardened runtime is on; there is no sandbox in v1.

| Entitlement | Decision | Reason |
|---|---|---|
| `com.apple.security.app-sandbox` | off in v1 | We need read access across `~` (other apps' Application Support, `~/.claude`, worktrees anywhere), `FileManager.trashItem` on those paths, and to spawn `git`/`docker`/`ollama` CLIs. A sandboxed build would need a user-granted security-scoped bookmark per root and couldn't exec arbitrary CLIs. Revisit for the Mac App Store (non-goal, PLAN §3). |
| `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation`, `cs.allow-dyld-environment-variables`, `cs.disable-executable-page-protection` | not needed | Pure Swift, no JIT, no plugins. Leaving them out keeps the hardened runtime fully effective. |
| `com.apple.security.automation.apple-events` | not needed | "Reveal in Finder" uses `NSWorkspace.activateFileViewerSelecting`, which isn't Apple Events. |
| `com.apple.security.files.*` | not applicable | These apply to sandboxed apps only. |
| Full Disk Access | not an entitlement | It is a TCC grant made by the user (onboarding T11). |
| Notifications (T22), login item (`SMAppService`) | not needed | No entitlement is required when not sandboxed. |

**Adding any entitlement requires updating this table in the same PR.**

## 7. Troubleshooting

- *"The signature does not include a secure timestamp"*: the runner/host can't reach `timestamp.apple.com`.
- `errSecInternalComponent`: the keychain is locked or the key partition list wasn't set (`security set-key-partition-list`).
- Notary status **Invalid**: read the log printed by `notarize.sh`.
- *"The executable does not have the hardened runtime enabled"*: the app was not signed by `sign-app.sh` (needs `--options runtime`).
- `spctl` says *rejected* on an unsigned build: expected.

## 8. Rotating or expiring credentials

Developer ID certificates last 5 years: create a new one, re-export the `.p12`, and update
`MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` (and `MACOS_SIGNING_IDENTITY` if set).
The App Store Connect API key can be revoked and replaced at any time; update the three `NOTARY_API_*` secrets.
