# key54.app — content compression + Explore tabs (2026-07-02)

Approved design from the site audit (3 fresh-eyes lenses + hands-on demo test).
Brief: reduce repetitive copy, keep it informative but not overwhelming,
"simple like the app." Owner vetoes: keep ALL cards and ALL outbound
competitor links.

## 1. Explore section (tabbed slider)
- Merge "Why Key54?", "Ways to use it.", "Not another launcher." into one
  `<section id="explore">` with a macOS-style segmented control:
  `Why Key54 · Ways to use it · vs. Other tools`.
- Panels slide horizontally (translateX track, ~0.45s ease); container height
  animates to the active panel; `prefers-reduced-motion` gets instant swaps.
- Real tab semantics: `role=tablist/tab/tabpanel`, arrow-key navigation,
  `aria-selected`. Touch swipe switches panels on mobile.
- Panel divs keep ids `features` / `examples` / `comparison`; JS intercepts
  hash navigation to activate the right tab and scroll to the section, so all
  existing anchors/inbound links keep working. Default panel: Why Key54.
- Per-panel h2s are replaced by the segment labels; lead paragraphs stay.

## 2. In-card copy (surgical, no card or link removed)
- Example cards: strip the repeated "one hold … one hold back" scaffolding;
  each card names only what's distinct about the scenario.
- Comparison: delete the "Honestly, you can really use it for anything you
  want." hedge; trim the lead's pre-summary clause; row-4 vs-line keeps only
  the differentiator.
- "Out and back" card: drop "Other switchers make you find your own way
  back."; reframe around returning even when the app wasn't running.
- Mic card: make the mechanism honest — Shortcuts saved as an app
  (File → Add to Dock) is what you bind.
- Dedupe: "About 1 MB," leaves the Tiny & invisible card (hero meta keeps it);
  "Free & open source." leaves the footer brand blurb (fine print keeps it).

## 3. Rest of the page
- Hero paragraph gains "the app you choose"; core loop then lives ONLY in
  hero + demo.
- Demo: caption "Terminal here — you pick any app in settings." + instruction
  wording that works on touch.
- New closing CTA band after the setup stepper: tagline + Download button +
  brew copy pill (hero components), plus one trust line: first-launch
  Accessibility permission, listen-only, open source.
- Setup section notes how to reopen settings (relaunch from Applications /
  Spotlight).
- Support + feedback merge into one slim band (id="contribute"): one sentence
  + Star / Tip / Report-a-bug buttons; the pre-filled issue form is removed
  (GitHub issue link replaces it).
- Nav menu + footer Explore column updated to the new section map.

## Out of scope
- Reddit post + screen-recorded GIF (separate task; GIF also serves README).
