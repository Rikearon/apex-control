# PRD-18: Product Polish & Onboarding

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** — (independent)
- **Firmware basis:** **host-side only** — no new device commands.

## 1. Summary
The control engine is done; this PRD closes the product-quality gaps that separate
"works" from "shippable": an **app icon** and branding, a **first-run onboarding**
flow, **accessibility**, **localization scaffolding**, and proper **distribution**
(Developer ID signing + notarization + a DMG + in-app auto-update). Cloud accounts,
sync, and telemetry are an explicit, permanent **non-goal** — privacy with no account
is a selling point, not a missing feature.

## 2. Background & GG parity
Apex Control today launches straight into a bare window, is **ad-hoc signed** (so
Gatekeeper warns on first open), has **no icon**, and keeps all UI strings
**hardcoded**. None of these are engine problems, but together they are what makes a
tool feel trustworthy enough to keep. This is *polish*, not new capability — but it is
the difference between a demo and a product.

## 3. Technical basis (grounded)
- **App icon / branding (host-side, trivial protocol-wise).** `Scripts/build-app.sh`
  writes an `Info.plist` with **no** `CFBundleIconFile` and an empty `Resources`
  directory; the app currently has no icon. `Theme.signal` is already the app's own
  signal orange (`RGB 1.0, 0.29, 0.0`). **Trademark caveat:** the project
  is unofficial (the README states it) — we must ship our **own** mark and name, not
  SteelSeries logos.
- **Onboarding / permissions (confirmed).** `KeyMonitor` gates reactive lighting on
  either of two macOS permissions, **Input Monitoring** or **Accessibility**
  (`IOHIDCheckAccess` / `AXIsProcessTrusted`; `KeyMonitor.requestPermission` asks for
  both, and Input Monitoring's prompt is the reliable one); the same permission will be
  needed for macro capture (PRD-04). **Everything else needs no permission**
  (vendor-HID access is unentitled — confirmed). Two different "accessibility"
  meanings must be disambiguated in copy: the Accessibility *permission* vs.
  accessibility *(a11y — VoiceOver, Dynamic Type)*.
- **Distribution (host-side, well-trodden).** Today `codesign --sign -` (ad-hoc).
  Developer ID signing + `notarytool` submission + `stapler` is the standard path;
  a DMG via `hdiutil` / `create-dmg`; auto-update via **Sparkle** with an
  EdDSA-signed appcast. All independent of the device protocol.
- **Accessibility / localization / logging.** SwiftUI supports a11y modifiers,
  Dynamic Type, and Reduce Motion (`accessibilityReduceMotion`) — relevant to the
  animated `LightingView` previews and the drawn `KeyboardView`. Strings are
  hardcoded today and must move to a String Catalog. There is **no logging** today —
  errors are `try?`-swallowed throughout `DeviceController` — so an `os.Logger`
  layer plus surfaced errors is part of the reliability work.

## 4. Goals / Non-goals
- **Goals:** app icon + branding; first-run onboarding (detect, permission
  explainer, quick tour); accessibility (VoiceOver, full keyboard navigation, Dynamic
  Type, Reduce Motion); localization scaffolding; distribution (Developer ID,
  notarization, DMG, Sparkle); reliability niceties (reconnect polish, error
  surfacing, logs + export).
- **Non-goals:**
  - **Cloud accounts, config sync, telemetry, or analytics — explicitly and
    permanently out.** No-account, no-tracking is the pitch (FEATURE-GAP §E).
  - **Full translation** of every language — this PRD delivers the *scaffolding*
    plus at most one pilot locale.
  - **Importing settings from SteelSeries GG**, or reading any other program's private
    files. Those formats are undocumented and can change with any release. Apex
    Control's own profiles export and import as JSON (PRD-06).
  - The menu-bar app / launch-at-login (that is PRD-15).

## 5. User stories
- As a new user, I want a recognizable icon and a short setup that detects my
  keyboard and explains what (little) permission I actually need.
- As a VoiceOver user, I want to navigate and adjust every setting without a mouse.
- As a non-English user, I want the app in my language (eventually).
- As a security-conscious user, I want a signed, notarized app that updates itself
  without an account or any tracking.
- As a bug reporter (and as the maintainer), I want to grab a log when something
  breaks so a report is actionable.

## 6. Functional requirements
- FR-1: Ship an app icon (`.icns`, all required sizes) and set `CFBundleIconFile`
  in `build-app.sh`; the mark must be distinct and non-infringing.
- FR-2: First-run onboarding: (a) **detect** the keyboard (reuse
  `DeviceController.isConnected`) with connected / not-connected states;
  (b) **explain** the optional key-monitoring permission (Input Monitoring or
  Accessibility; either is enough) — needed *only* for reactive lighting and macro
  capture — with a grant button (`KeyMonitor.requestPermission`) and a clear
  "skip; everything else works without it" path; (c) a 3–4 screen **tour** of
  Lighting / Actuation / OLED / Profiles; (d) shows once, and is re-openable from a
  Help menu.
- FR-3: Accessibility: VoiceOver labels/values on every control **including the
  on-screen keyboard**; full keyboard navigation; Dynamic Type; honor Reduce Motion
  (freeze or slow the effect previews); honor Reduce Transparency; verify contrast
  of the dark theme.
- FR-4: Localization scaffolding: externalize **all** user-facing strings to a
  String Catalog; use formatters for numbers/units (e.g. mm); add a pseudo-locale
  build for leak detection; ship at least `en` with the structure ready for more.
- FR-5: Distribution: Developer ID sign → notarize → staple; a DMG with a
  drag-to-Applications layout; a Sparkle appcast with EdDSA signing and a
  "Check for updates…" menu item; keep the ad-hoc path for local dev builds.
- FR-6: Reliability: preserve the working reconnect behavior (already partial in
  `handleConnectionChange`); **surface real errors** to the UI instead of the
  current `try?` swallowing (a non-blocking banner); add `os.Logger` with an
  **Export logs** action.

## 7. UX / UI design
- **Onboarding:** a separate sheet/window on first launch — *Welcome → Detect →
  Permission (optional) → Quick tour → Done* — fully skippable, and re-openable
  later from Help.
- **Settings / About pane:** *About* (app version, firmware / LED firmware / region —
  shared with PRD-16); *Updates* (Sparkle); *Accessibility* notes; *Diagnostics*
  (export logs); *Reset*.
- **Empty / error states:** permission denied → reactive lighting falls back to a
  static background (already the behavior), explained rather than silent; keyboard
  absent → onboarding says "plug it in — it'll resume automatically."

## 8. Technical design
- **App:** `OnboardingView` + `OnboardingState` (persist a "seen" flag in
  `UserDefaults`); `SettingsView` / `AboutView`; a `Diagnostics` layer over
  `os.Logger`; error surfacing via a published `lastError` on `DeviceController`
  driving a banner (replacing the silent `try?` calls).
- **Build / distribution:** extend `build-app.sh` (icon, Developer ID identity,
  `notarytool`, `stapler`); add a `make-dmg.sh`; add **Sparkle** as a SwiftPM
  dependency; host an appcast (see §12).
- **Data model:** `OnboardingState`; a Localizable String Catalog; **no persisted
  PII** anywhere.

## 9. Edge cases & risks
- **Trademark.** Do not ship SteelSeries logos or name as our icon/branding; keep
  the "independent, unofficial, not affiliated" disclaimer (already in the README)
  visible in About.
- **Notarization + hardened runtime.** The hardened runtime may require the app to
  declare its use of the `CGEvent` tap (Input Monitoring); verify reactive lighting
  and macro capture still work **after** notarization. Vendor-HID access needs no
  special entitlement (confirmed) but must be re-tested under the hardened runtime.
- **Sparkle supply chain.** The appcast must be EdDSA-signed and served over HTTPS;
  a compromised feed is a remote-code-execution vector — pin the public key in the
  app.
- **Privacy.** No analytics. The update check is the only network request, and it can
  be switched off; state this plainly in the UI/About so it is a visible promise, not
  an assumption. (Today the app makes no network connections at all, so adding Sparkle
  changes what `docs/PRIVACY.md` and the CI network check say.)
- **Accessibility of the custom keyboard view.** `KeyboardView` is drawn, not built
  from native controls, so it is invisible to VoiceOver unless we add explicit
  accessibility elements per key.
- **Reduce Motion.** The continuous effect previews can be a vestibular trigger; a
  static preview must be offered when Reduce Motion is set.

## 10. Acceptance criteria
- AC-1: The app shows a custom icon in Finder, the Dock, and About.
- AC-2: First launch shows onboarding once; it detects the connected state and
  explains the permission; **skipping** still leaves a fully working app; it is
  re-openable from Help.
- AC-3: VoiceOver can traverse and operate every pane including the keyboard;
  Reduce Motion stops effect animation; Dynamic Type scales the text.
- AC-4: Every visible string resolves through the String Catalog (a pseudo-locale
  build shows no hardcoded leaks).
- AC-5: A Developer-ID-signed, notarized DMG installs with **no** Gatekeeper
  warning; Sparkle performs a signed update; the app makes **no** network calls
  beyond the explicit appcast fetch.
- AC-6: A forced device error produces a **user-visible** message (not a silent
  no-op), and logs can be exported.

## 11. Effort & milestones
**M–L overall; each track ships independently.**
- M1: icon + onboarding + About/Settings pane + error surfacing / logging (all
  unblocked, high perceived value).
- M2: accessibility + localization scaffolding.
- M3: distribution — Developer ID, notarization, DMG, Sparkle.

## 12. Open questions
- Icon: commission an original mark vs. generate one — and confirm it is
  non-infringing.
- Which hardened-runtime entitlements (if any) does the `CGEvent` tap need under
  notarization?
- Where to host the Sparkle appcast so it stays privacy-preserving (HTTPS, no
  request logging/identifiers)?
- Which pilot locale ships first?
