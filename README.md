# Key54

[![Latest release](https://img.shields.io/github/v/release/grokcodile/key54?sort=semver&label=release)](https://github.com/grokcodile/key54/releases/latest)
[![Homebrew](https://img.shields.io/badge/Homebrew-grokcodile%2Ftap-C9782E?logo=homebrew&logoColor=white)](https://github.com/grokcodile/homebrew-tap)
[![Downloads](https://img.shields.io/github/downloads/grokcodile/key54/total)](https://github.com/grokcodile/key54/releases)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111111)](#requirements)
[![License: MIT](https://img.shields.io/github/license/grokcodile/key54)](LICENSE)

<img src="docs/icon.png" alt="Key54 Icon" width="96"/>

**Key54** is a tiny macOS utility that binds one app of your choice to the right Command key (keycode 54). Hold the right ⌘ to summon that app; hold it again to switch back to what you were doing. A built-in hold delay keeps quick taps and your normal right-⌘ shortcuts working as usual.

It runs as a background agent — no Dock icon, no menu bar item — and starts at login.

<p>
  <a href="https://key54.app"><img src="https://img.shields.io/badge/Website%20%26%20more%20info%20%E2%86%92-key54.app-0071e3?style=for-the-badge" alt="Website & more info"></a>
</p>

## Features

- Hold right-⌘ to toggle one chosen app in and out of focus; hold again to return.
- Works with any application.
- **Hold Duration** presets (Instant / Short / Medium / Long / Custom) with a built-in Key Delay, so quick taps and normal right-⌘ shortcuts aren't hijacked.
- A charge animation on a Liquid Glass bezel (macOS 26+; frosted glass on older systems), in two styles — **Power Up** and **Level Up** — following your System Settings accent color.
- Correctly returns you to the previous app, including full-screen apps and apps with no open windows.
- Runs silently as a background agent and starts at login.

## Screenshot
![Settings Window](/docs/settings.png)

## Install

### Homebrew (easiest — also handles updates)

```sh
brew install --cask grokcodile/tap/key54
```

New versions arrive with `brew upgrade --cask key54`.

### Download the disk image

1. Download the latest **[Key54.dmg](https://github.com/grokcodile/key54/releases/latest/download/Key54.dmg)** (or browse [all releases](https://github.com/grokcodile/key54/releases)).
2. Open the `.dmg` and drag **Key54** into your `Applications` folder.

The released build is signed with a Developer ID and notarized by Apple, so it opens normally — no "unidentified developer" warning. macOS may show a one-time "downloaded from the Internet" confirmation; just click **Open**.

> **Apple Silicon only.** The released `.dmg` is arm64; it won't run on Intel Macs — [build from source](#build-from-source) instead.

### Build from source

Works on any Mac (including Intel):

```sh
bash install.sh
```

This compiles `main.swift`, generates the app icon (`make_icon.swift`), ad-hoc code-signs, installs to `/Applications/Key54.app`, and launches it. An ad-hoc build isn't notarized, so its first launch shows the "unidentified developer" warning — clear it once by right-clicking **Key54 → Open**.

> Optional: install [`pngquant`](https://pngquant.org) to shrink the generated icon.

## Requirements

- macOS 13 or later.
- **Apple Silicon** for the released `.dmg` (Intel Macs can [build from source](#build-from-source)).
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility) so it can detect the right Command key.

## First run

1. Launch **Key54** from `Applications`. Its window opens.
2. Grant **Accessibility** permission when prompted — System Settings → Privacy & Security → Accessibility → enable Key54. This lets it detect the right Command key.
3. Click **Change Application…** and pick the app you want bound to the right ⌘ key.
4. Optionally pick a **Hold Duration** preset (how long you hold before it triggers) — or choose **Custom** and dial in your own timings — and an **Animation Style** (Power Up or Level Up).
5. Click **Done**. Key54 keeps running in the background (and starts automatically at login).

To change the app or settings later, just open Key54 again from `Applications`.

## Hold Duration

The slider in settings controls how long you hold the right ⌘ key before the switch fires — and how much ceremony comes with it. Short, Medium, and Long each start with a brief **Key Delay** (nothing appears yet, and letting go does nothing), followed by the charge animation you can watch fill. Release any time before it completes and the switch is cancelled.

| Preset | Hold to trigger | Behavior |
| --- | --- | --- |
| **Instant** | A press — no hold | Completely hands the right ⌘ key to Key54: no hold, no delay, no animation — the moment you press, you've switched. Quick taps and right-⌘ shortcuts trigger it too, so pick this only if you're dedicating the key. |
| **Short** | ~0.5 s | A snappy switch that still leaves normal right-⌘ shortcuts usable — anything shorter than the half-second Key Delay is ignored. No charge animation; the app's icon simply appears and dissolves into the switch. |
| **Medium** *(default)* | ~0.9 s (0.5 s Key Delay + 0.4 s animation) | The best mix: enough delay to cancel the switch early just by letting go, a smooth transition, and still quick and responsive. |
| **Long** | ~1.3 s (0.7 s Key Delay + 0.6 s animation) | A more generous, deliberate task-switch — maximum time to watch it fill and change your mind. |
| **Custom** | Your call — up to 1.5 s + 1.5 s | Build your own: **Key Delay** and **Animation Length** sliders appear in a panel below, adjustable in 0.05 s steps — and your values are remembered, even while trying other presets. A zero Animation Length gives Short's icon-only flash; zero both and it behaves like Instant. |

## Animation Style

Pick how the hold is visualized while it charges. It only affects the presets that actually animate (Short / Medium / Long / Custom), and both styles follow your System Settings accent color on the Liquid Glass bezel:

- **Power Up** — the chosen app's icon inside a glowing accent ring that sweeps to full as you hold.
- **Level Up** — a larger icon over a glass that fills with your accent color as you hold, like a level meter topping off.

## Uninstall

1. Open Key54 and click **Quit** (or toggle the switch to Disabled and click **Done**). (Or `killall Key54`.)
2. Drag **Key54** from `Applications` to the Trash.
3. Optionally remove its entry under System Settings → Privacy & Security → Accessibility.

## Releases

Releases are cut entirely by GitHub Actions (`.github/workflows/release.yml`).
To publish a new version, push a version tag — that's the whole process:

```sh
git tag v1.18
git push origin main --tags
```

The workflow then automatically:

1. **Stamps the version from the tag** (`v1.18` → `1.18`) into `Info.plist`, so the app version can never drift from the release — you never edit the version by hand.
2. **Builds and signs** the app (Developer ID, Hardened Runtime, secure timestamp).
3. **Notarizes and staples both the app and the `.dmg`**, so a copy dragged out of the DMG launches cleanly even offline.
4. **Publishes `Key54.dmg`** to the matching GitHub Release — exactly what the [Install](#install) download link points to.

**One-time setup.** Add these repository secrets (Settings → Secrets and
variables → Actions). With all five set, the workflow signs + notarizes; without
them it falls back to an ad-hoc `.dmg` that triggers a Gatekeeper warning — so
set them before any public release:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | Base64 of your exported **Developer ID Application** cert (`.p12`) |
| `MACOS_CERT_PASSWORD` | Password for that `.p12` |
| `AC_API_KEY_ID` | App Store Connect API **Key ID** |
| `AC_API_ISSUER_ID` | App Store Connect API **Issuer ID** |
| `AC_API_KEY_BASE64` | Base64 of the `AuthKey_XXXX.p8` |

> Want a dry run? Trigger the workflow manually from the **Actions** tab — it
> builds and notarizes but skips publishing (no tag, no release).

## How it works

Key54 watches `flagsChanged` events for the right Command key (keycode 54) with a **listen-only** session `CGEventTap`, serviced on a dedicated thread. Listen-only means the tap only ever *observes* events — the system never waits on it, so it can't block, delay, or drop input (even if Accessibility is revoked while running). A session-level tap also keeps seeing keys during Space switches and full-screen transitions, so the trigger fires reliably no matter which app or Space is up. A sustained hold past the configured duration toggles the chosen app via `NSWorkspace`; full-screen and window-state edge cases are handled with the Accessibility API.

## The name

**54** is the macOS keycode for the right Command key — the exact key this app
claims. (You can see it in the source: the event tap watches for `keycode 54`.)
So **Key54** is literally that — the key, named by its number.

## Notes

This app uses a global event tap and controls other applications, which is incompatible with the Mac App Store sandbox — it's distributed directly (Developer ID + notarization, or built from source).

## License

Released under the [MIT License](LICENSE).
