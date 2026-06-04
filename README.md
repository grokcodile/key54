# Trapdoor

A tiny macOS utility: **hold the Command (⌘) key on the right side of your keyboard to summon a chosen application. Hold it again to dismiss it and return to what you were doing.**

It repurposes the otherwise-unused *gesture* of holding the right Command key — quick taps and normal right-⌘ keyboard shortcuts still work as usual, so you don't lose the modifier. Pick one app you bounce to constantly (a terminal, notes, chat, etc.) and it becomes a single-key reflex, like a push-to-talk button for that app.

## Features

- Hold right-⌘ to toggle a single chosen app in and out of focus.
- Works with **any** application, not just terminals.
- Adjustable **hold duration** (0–0.6s) so a normal press of right-⌘ is never hijacked.
- Correctly returns you to the previous app — including full-screen apps and apps with no open windows.
- Runs silently as a background agent (no Dock icon, no menu bar), and starts at login.

## Requirements

- macOS 13 or later.
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility) so it can detect the right Command key.

## Build & install

```sh
bash install.sh
```

This compiles `main.swift`, generates the app icon from `trapdoor_icon.png`, ad-hoc code-signs, installs to `/Applications/Trapdoor.app`, and launches it. On first run, grant Accessibility permission when prompted.

> Optional: install [`pngquant`](https://pngquant.org) to shrink the generated icon.

## Releases

Pushing a version tag (e.g. `v1.0`) triggers the GitHub Actions release workflow
(`.github/workflows/release.yml`), which builds the app, packages a `.dmg`, and
attaches it to a GitHub Release.

```sh
git tag v1.0
git push origin v1.0
```

By default the `.dmg` is ad-hoc signed (other Macs will show a Gatekeeper
warning). To produce a signed + notarized build, add these repository secrets
(Settings → Secrets and variables → Actions) — the workflow detects them
automatically:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | Base64 of your exported **Developer ID Application** cert (`.p12`) |
| `MACOS_CERT_PASSWORD` | Password for that `.p12` |
| `AC_API_KEY_ID` | App Store Connect API **Key ID** |
| `AC_API_ISSUER_ID` | App Store Connect API **Issuer ID** |
| `AC_API_KEY_BASE64` | Base64 of the `AuthKey_XXXX.p8` |

## How it works

Trapdoor installs a `CGEventTap` that watches `flagsChanged` events for the right Command key (keycode 54). A sustained hold past the configured duration toggles the chosen app via `NSWorkspace`; full-screen and window-state edge cases are handled with the Accessibility API.

## Notes

This app uses a global event tap and controls other applications, which is incompatible with the Mac App Store sandbox — it's distributed directly (Developer ID + notarization, or built from source).

## License

Personal project.
