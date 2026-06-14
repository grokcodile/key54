<img src="screenshots/icon_readme.png" width="128" alt="Cmd54 icon">

# Cmd54

**Hold the Command (⌘) key on the right side of your keyboard to summon one chosen app — hold it again to switch back to whatever you were doing.**

Cmd54 isn't another app library switcher, launcher, or palette. It doesn't try to replace ⌘-Tab, Mission Control, or Spotlight, and it doesn't pile on the features that tools like Raycast, Alfred, LaunchBar, rcmd, or Monarch already do well. It does exactly one thing: a single, dedicated key for the *one* app you reach for constantly.

There's nothing to launch, no fuzzy search, no list of shortcuts to memorize, and no chords. You pick the app once; after that it's pure muscle memory — like a push-to-talk button for your terminal, notes, browser, or chat. It claims the otherwise-dead *gesture* of holding the right ⌘ key, so quick taps and normal right-⌘ shortcuts keep working exactly as before (unless you opt into the Instant preset) — you give up nothing.

And it's calm by design. Instead of racing to ⌘-Tab across your desktop and back, you hold the key and it charges for a beat before it fires — a small, deliberate pause that lets your brain settle into the switch (dial it to Instant if you'd rather skip it). One key, one app, no chord to remember: a context switch that gives you a moment to breathe.

It's fast, tiny (2.3 MB), uses almost zero system resources, and stays out of the way: no Dock icon, no menu bar clutter.

## Screenshot

![Cmd54 settings window](screenshots/settings.png?v=5)

## Download

**Download the latest [Cmd54.dmg](https://github.com/grokcodile/cmd54/releases/latest/download/Cmd54.dmg) — or see [all releases](https://github.com/grokcodile/cmd54/releases/latest).** *This link always points to the most recent release build.*

Open the `.dmg` and drag **Cmd54** into your `Applications` folder.

> **Apple Silicon only.** The released build is arm64; it won't run on Intel Macs. Intel users can [build from source](#build).
>
> **First launch:** the build isn't notarized yet, so macOS will warn that it's from an unidentified developer. You only need to clear this once, in any of these ways:
>
> - **macOS 13–14:** right-click (or Control-click) **Cmd54 → Open**, then click **Open** in the dialog.
> - **macOS 15 (Sequoia) and later:** double-click it (it gets blocked), then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
> - **Terminal (any version):** `xattr -dr com.apple.quarantine /Applications/Cmd54.app`
>
> Prefer no warning at all? [Build from source](#build) — a locally built app isn't quarantined and just runs.

## Features

- Hold right-⌘ to toggle a single chosen app in and out of focus.
- **One key, held — no chord.** No ⌘-key combination, no rapid tapping, no sequence to remember; just hold one key. Pure muscle memory, and a gentler reach than ⌘-Space or ⌘-Tab (see [Accessibility](#accessibility)).
- Works with **any** application of your choice.
- **Hold-duration presets** (Instant / Short / Medium / Long / Custom) with a built-in dead-zone, so a quick press or normal right-⌘ shortcut is never hijacked. **Instant** skips the animation entirely and switches the moment you press; **Custom** lets you tune the timings yourself.
- A subtle **charge animation** — the chosen app's icon in a glowing ring on a Liquid Glass bezel (macOS 26+; frosted glass on older systems) — plays as you hold and dissolves as it switches. The ring follows the accent color you've chosen in System Settings.
- Correctly returns you to the previous app — including full-screen apps and apps with no open windows.
- Runs silently as a background agent (no Dock icon, no menu bar), and starts at login.

## Usage Examples

Pick the one app you're *always* dropping into and back out of, bind it with Cmd54, and forget the keyboard gymnastics.

- **Developer** — bind the terminal of your choice (Terminal.app, Warp, Ghostty, iTerm). It's one key away from anywhere: `brew install` something mid-task, check a deploy script, fire off a quick `git` command — then one key back to what you were doing. And it's the **full app**, with all its tabs and sessions, not a stripped-down dropdown drawer, global hotkey window, or limited notch gimmick.

- **Researcher** — bind your browser (Safari, Chrome, Arc). Reading a doc or writing something and need to look a thing up? One tap brings the real browsing session forward, one tap returns to the work — no new window, no "search the web" box.

- **Note Taker** — bind your favorite notes app (Notes, Obsidian, Bear). A thought worth capturing never means hunting for the right window: one tap to the notebook, jot it down, one tap back. The capture friction basically disappears.

- **Manager** — bind your email or chat client (Mail, Messages, Slack). Glance at a message and reply, then drop straight back into focus — without getting sucked in and losing the thread of deeper work.

Whatever you assign as your **Cmd54**, the pattern is the same: **summon → do the thing → dismiss** — without ever breaking stride or wondering which shortcut to press.

## Accessibility

Cmd54 needs only a **single key, held** — the right ⌘ key on its own, no multi-finger chord, no rapid tapping, no sequence to remember. For anyone who finds combinations like ⌘-Space or ⌘-Tab hard to reach or hold, holding one key to bring an app forward — and holding it again to go back — can be a genuinely simpler way to move between apps.

The timing is forgiving, too: a quick or accidental press does nothing, and you can let go any time before the ring fills to cancel. Cmd54 was built as a convenience, but the same no-chord, no-reach interaction turns out to be an accessibility aid — and honestly, a little easier for everyone.

## Hold Duration

The slider in settings controls how long you hold the right ⌘ key before the switch fires — and how much ceremony comes with it. Short, Medium, and Long each start with a *dead-zone* (nothing appears yet, and letting go does nothing), followed by a charge ring you can watch fill. Release any time before the charge completes and the switch is cancelled.

| Preset | Hold to trigger | Behavior |
| --- | --- | --- |
| **Instant** | A press — no hold | Completely hands the right ⌘ key to Cmd54: no hold, no delay, no animation — the moment you press, you've switched. Quick taps and right-⌘ shortcuts trigger it too, so pick this only if you're dedicating the key. |
| **Short** | ~0.5 s | A snappy switch that still leaves normal right-⌘ shortcuts usable — anything shorter than the half-second dead-zone is ignored. No charge ring; the app's icon simply appears and dissolves into the switch. |
| **Medium** *(default)* | ~0.9 s (0.5 s dead-zone + 0.4 s charge) | The best mix: enough delay to cancel the switch early just by letting go, a smooth transition that supports a more graceful mental shift between tasks, and still quick and responsive. |
| **Long** | ~1.3 s (0.7 s dead-zone + 0.6 s charge) | An even more generous, deliberate task-switching experience — maximum time to watch the ring fill and change your mind. |
| **Custom** | Your call — up to 1.5 s + 1.5 s | Build your own: dead-zone and charge sliders appear in a panel below, adjustable in 0.05 s steps — and your values are remembered, even while trying other presets. A zero charge gives Short's icon-only flash; zero both and it behaves like Instant. |

## Requirements

- macOS 13 or later.
- **Apple Silicon** — the released `.dmg` is arm64-only. (Intel Macs can build from source.)
- **Accessibility permission** (System Settings → Privacy & Security → Accessibility) so it can detect the right Command key.

## Build

```sh
bash install.sh
```

This compiles `main.swift`, generates the app icon (`make_icon.swift`), ad-hoc code-signs, installs to `/Applications/Cmd54.app`, and launches it. On first run, grant Accessibility permission when prompted.

> Optional: install [`pngquant`](https://pngquant.org) to shrink the generated icon.

## First run

1. Launch **Cmd54** from `Applications`. Its window opens.
2. Grant **Accessibility** permission when prompted — System Settings → Privacy & Security → Accessibility → enable Cmd54. This lets it detect the right Command key.
3. Click **Change Application…** and pick the app you want bound to the right ⌘ key.
4. Optionally pick a **Hold Duration** preset (how long you hold before it triggers) — or choose **Custom** and dial in your own timings.
5. Click **Done**. Cmd54 keeps running in the background (and starts automatically at login).

To change the app or settings later, just open Cmd54 again from `Applications`.


## Uninstall

1. Quit Cmd54 (open it and click **Quit**, or `killall Cmd54`).
2. Drag **Cmd54** from `Applications` to the Trash. This also removes its login item.
3. Optionally remove its entry under System Settings → Privacy & Security → Accessibility.

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

Cmd54 installs a `CGEventTap` that watches `flagsChanged` events for the right Command key (keycode 54). A sustained hold past the configured duration toggles the chosen app via `NSWorkspace`; full-screen and window-state edge cases are handled with the Accessibility API.

## The name

**54** is the macOS keycode for the right Command key — the exact key this app
claims. (You can see it in the source: the event tap watches for `keycode 54`.)
So the name isn't a number plucked from thin air; it's the app's whole job
written as a coordinate.

There's a second layer, too. The ⌘ symbol is `U+2318`, which Unicode officially
names **"PLACE OF INTEREST SIGN."** Susan Kare borrowed the glyph — a looped
square, or *Bowen knot* — from Swedish road signs that mark a spot worth
visiting. Which is a fitting origin for a key whose whole purpose here is to take
you to the one place you care about, then loop you right back.

## Notes

This app uses a global event tap and controls other applications, which is incompatible with the Mac App Store sandbox — it's distributed directly (Developer ID + notarization, or built from source).

## Support

Cmd54 is free and open source. If it makes your work a little better, you can support its development:

- ❤️ [GitHub Sponsors](https://github.com/sponsors/grokcodile)
- ☕ [Ko-fi](https://ko-fi.com/grokcodile)

## License

Released under the [MIT License](LICENSE).
