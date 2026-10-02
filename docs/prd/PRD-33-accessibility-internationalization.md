# PRD-33: Accessibility & Internationalization

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** — (touches every view; cheapest to do before the view count grows again)
- **Firmware basis:** none, except that the keyboard reports its **physical
  layout** (`read_layout`, `0xF2`) and **region** (`read_region`, `0xF5`), which
  is exactly the information needed to label keys correctly.

## 1. Summary
The app's central control is a picture of a keyboard built from coloured
rectangles, and its main data view is a hue-coded heat map. Both are close to
unusable with VoiceOver or with a colour-vision deficiency, and every string in
the app is a hard-coded English literal. This PRD makes the app usable without
sight, without colour discrimination, without a mouse, and in a language other
than English — including labelling keys the way they are actually printed on the
user's keyboard.

## 2. Background & GG parity
Not a parity feature: the benchmark is the platform, not other keyboard software.
macOS users expect full keyboard navigation, VoiceOver, Dynamic Type, Reduce
Motion, and Increase Contrast to work everywhere. There is also a specific irony
worth naming — this is a **keyboard configuration app**, so its users
disproportionately include people who navigate by keyboard, remap keys for RSI or
motor reasons, and rely on Caps Lock as Control. Shipping a mouse-only configurator
for that audience is a poor look.

Some groundwork already exists: the keyboard view takes a `describe` closure for
per-key accessibility labels, marks selection traits, and honours Reduce Motion.
This PRD finishes the job rather than starting it.

## 3. Technical basis (grounded)
- **Accessibility** (documented AppKit/SwiftUI): `.accessibilityLabel`,
  `.accessibilityValue`, `.accessibilityHint`, `.accessibilityAddTraits`,
  `.accessibilityElement(children:)`, `AccessibilityCustomContentKey` for the
  rich per-key detail, and `.accessibilityRepresentation` where a custom control
  needs to present as a standard one. The keyboard view is a `ZStack` of shapes
  positioned absolutely — VoiceOver needs an explicit, ordered element tree, and
  `.accessibilitySortPriority` or a container that walks the layout row by row.
- **Colour**: the actuation heat map maps level → hue (cyan → magenta), which is
  the classic failure case for red-green and blue-yellow deficiencies, and it
  encodes a *quantitative* value in hue alone. The fix is redundant encoding —
  value labels, a numeric readout, and an optional pattern or lightness ramp —
  not a different palette.
- **Reduce Motion / Increase Contrast / Reduce Transparency**: available as
  SwiftUI environment values; the new keyboard render deliberately uses depth,
  bloom, and gradients, all of which need a flat fallback.
- **Localization** (documented, and SwiftPM supports it): String Catalogs
  (`.xcstrings`) with `String(localized:)`; `defaultLocalization` in
  `Package.swift`; `Bundle.module` for resource lookup in a SwiftPM target.
- **Key legends are a localization problem too** (confidence: grounded in our own
  protocol): `read_layout` returns ANSI/ISO/JIS and `read_region` returns US, UK,
  Germany, France, Nordic, Japan, Turkish. The app currently prints US legends on
  every key regardless. A German user's `Z` and `Y` are swapped, `;` is `Ö`, and
  the ISO key we already draw has no legend at all.

## 4. Goals / Non-goals
- **Goals:** full VoiceOver support including a navigable keyboard; complete
  keyboard navigation with visible focus; redundant (non-colour) encoding for all
  data displays; Reduce Motion / Increase Contrast / Reduce Transparency
  honoured; Dynamic Type support in text; all user-facing strings localizable;
  region-correct key legends driven by the device's own reported layout and
  region; at least one non-English localization to prove the pipeline.
- **Non-goals:** right-to-left *layout* mirroring of the keyboard picture (a
  keyboard is a physical object and does not mirror); localizing the protocol
  documentation; voice control beyond what standard controls give for free;
  translating community-contributed content.

## 5. User stories
- As a VoiceOver user, I can hear which key I am on, what it is bound to, and
  what its actuation is, and I can change it.
- As a keyboard-only user, I can reach and operate every control with Tab and
  arrow keys, and I can always see where focus is.
- As someone with deuteranopia, I can read the actuation heat map because the
  numbers are there too.
- As a German user, my keyboard on screen shows the legends printed on my actual
  keyboard.
- As a French speaker, the app is in French.
- As someone sensitive to motion, the interface does not animate.

## 6. Functional requirements
- FR-1: The keyboard view exposes each key as an accessibility element with a
  label (legend), a value (its current binding/actuation/colour depending on the
  pane), and custom content for the secondary details; elements are ordered
  physically, row by row, left to right.
- FR-2: Keys are selectable and adjustable from the keyboard: arrow keys move
  between physically adjacent keys, Space/Return selects, and the inspector is
  reachable with Tab.
- FR-3: A visible focus ring on every interactive element, meeting contrast
  requirements against the dark chassis.
- FR-4: Every data display that uses colour also conveys the value another way:
  the actuation map gains numeric labels at a threshold zoom and a value readout
  on focus/hover; the binding map already uses badges and keeps them.
- FR-5: Text meets WCAG AA contrast (4.5:1 body, 3:1 large) against its actual
  background, checked with a script over the theme, not by eye.
- FR-6: `Reduce Motion` disables transitions, the connection pulse, and effect
  animation *in the preview* (the hardware keeps running); `Increase Contrast`
  strengthens borders and disables the bloom layer; `Reduce Transparency`
  replaces translucent surfaces with solid ones.
- FR-7: Text scales with Dynamic Type; no view clips or truncates at the largest
  accessibility sizes; the keyboard render may stay fixed-ratio but its labels
  scale.
- FR-8: All user-facing strings move to a String Catalog with comments for
  translators; no string concatenation of sentence fragments (which is currently
  used in several panes and does not translate).
- FR-9: Key legends are chosen from the device's reported **layout** and
  **region**: ANSI/ISO/JIS geometry (already supported) plus per-region legend
  tables for at least US, UK, DE, FR, Nordic, JP.
- FR-10: A manual override for layout/region, because the device's report can be
  wrong and users can swap keycaps.
- FR-11: Every image/glyph that carries meaning has a label; decorative ones are
  hidden from accessibility.

## 7. UX / UI design
- **Keyboard navigation model:** the keyboard picture is one focusable group;
  entering it with Return moves focus to a key; arrows move by physical
  adjacency (not list order); Escape leaves the group. This is the part that
  needs to feel right — list-order navigation over a QWERTY layout is useless.
- **VoiceOver phrasing:** "W, bound to W, actuation 1.5 millimetres, adjustable"
  — legend first, because that is how the user identifies the key.
- **Heat map:** numeric value shown on the focused/hovered key at all times, and
  on every key when a "show values" toggle is on.
- **Settings → Appearance:** layout/region override, "show values on keys", and a
  note that motion and contrast follow System Settings.
- **Language:** follows the system; no in-app language picker.

## 8. Technical design
- **ApexKit:**
  - `KeyLegend` tables per region, keyed by HID usage, with the US table as the
    fallback; `Key.label` becomes a *default* and the legend is resolved at
    display time from `(layout, region)`.
  - `ApexProTKLGen3.keys(for:)` already handles ISO geometry; add JIS.
- **App:**
  - An `AccessibleKeyboard` layer over `KeyboardView` providing the element tree
    and adjacency-based focus movement.
  - A `Legends` environment value so every view labels keys consistently.
  - String Catalog; a lint script that fails the build on a literal string in a
    view file.
  - A contrast-checking test over the `Theme` colour pairs.
- **Data model:** `AppPrefs` gains `legendOverride: (layout, region)?` and
  `showValuesOnKeys`.

## 9. Edge cases & risks
- **Retrofitting is more expensive than it looks**: the keyboard view is
  absolutely positioned and drawn with `Canvas` in places, which accessibility
  does not see at all. The element tree has to be built deliberately.
- **String concatenation** is used today to assemble explanatory sentences; each
  one has to become a single localizable string with interpolation, or
  translations will be nonsense.
- **Legend tables are a long tail** — seven regions is a start, not completeness;
  the fallback must be graceful and the override always available.
- **Dynamic Type vs. a fixed-aspect keyboard**: at the largest sizes, key labels
  will not fit. The answer is a minimum scale plus the value readout elsewhere,
  not clipping.
- **Testing accessibility requires actually using VoiceOver**, which is a skill;
  budget for it rather than assuming labels are enough.
- **Contrast on the new chassis render**: the design deliberately uses dark
  metal; text over it must be checked programmatically, not judged.

## 10. Acceptance criteria
- AC-1: With VoiceOver on, a user can navigate to the `W` key, hear its binding
  and actuation, change the binding, and hear the confirmation — without a mouse.
- AC-2: Every interactive control is reachable by Tab with a visible focus ring.
- AC-3: A contrast test over all theme foreground/background pairs passes AA.
- AC-4: With Reduce Motion on, no transition or pulse animates.
- AC-5: Setting the region to Germany relabels `Z`/`Y`, `;`→`Ö`, `'`→`Ä`, and
  labels the ISO key.
- AC-6: Switching the system language to the shipped second locale translates the
  entire UI with no truncation at default Dynamic Type.
- AC-7: No view file contains a user-facing string literal (enforced by lint).

## 11. Effort & milestones
**L.** M1: accessibility element tree and adjacency focus for the keyboard view.
M2: focus rings, keyboard navigation, contrast audit. M3: redundant encoding for
heat maps + the values toggle. M4: string extraction to a catalog + the lint.
M5: legend tables and layout/region resolution. M6: one full translation.

## 12. Open questions
- What is the right VoiceOver model for a 91-key grid — individual elements, or a
  custom rotor with row/column navigation?
- Are the region legend tables worth building by hand, or can they be derived
  from macOS's own keyboard layout data (`TISCopyCurrentKeyboardLayoutInputSource`
  + `UCKeyTranslate`), which would cover far more locales for less work?
- Which second language, and who translates it? A machine translation shipped as
  a real localization is worse than English only.
- Should the *hardware* be usable as an accessibility output — e.g. lighting the
  key VoiceOver is focused on — or is that a gimmick that fights the user's
  chosen effect?
