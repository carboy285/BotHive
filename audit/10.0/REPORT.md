# 10.0 audit

_Branch `claude/eloquent-babbage-7xv8h1` (HEAD 3dc6651). Xcode 27.2. Audited 2026-11-14._

> **Device note:** this machine's Xcode has no "iPhone 16 Pro" or "iPhone SE (3rd generation)" simulator pre-created, and no iOS 18.x runtime for "iPhone 16 Pro" as written in the brief. I created both exact device types (`iPhone 16 Pro`, `iPhone SE (3rd generation)`) on the available iOS 27.2 runtime and installed/launched on them. The interactive walk-through was driven on an **iPhone 18 Pro** simulator (same build, same Pro-class size as 16 Pro) because the 16 Pro/SE simulator-control grant was stuck in a cooldown; small-screen checks used the **iPhone SE (3rd gen)** and large-text/dark checks used the 16 Pro / 18 Pro. See _Couldn't check_.
>
> **Mac note:** the Mac UI was audited on an isolated debug instance with a throwaway workspace and first-run flags, so the owner's own workspace was not used. Screenshots that showed account details (connected apps, initials, local paths) were removed before publishing this report.

## Build and tests
- **Mac build:** **pass** (compiled clean as part of the test action and the Release DMG build).
- **Mac tests:** **0 passed, 2 failed** — the `GrokBotMac` scheme ran only `GrokBotMacUITests` (2 UI tests); the `GrokBotMacTests` unit suite started 0 cases. Both UI tests failed (`** TEST FAILED **`, exit 65, 7 assertion failures in 209s):
  - `testFreshWorkspaceAndRealCLIProcessReply` — failed. First divergence at `GrokBotMacUITests/MacUITests.swift:41` (shift+Return draft newline assertion), cascading through `:44`, `:45`, `:49`, `:50` ("Failed to click 'bot-model-id-codex' TextField: No matches found"), `:106`.
  - `testGuidedSetupWithInstalledCLI` — failed at `GrokBotMacUITests/MacUITests.swift:96`.
  - **Caveat:** these UI tests ran **concurrently with the user's live Mac app** (same bundle id). XCUITest attaching/focus under a second same-id instance can produce element-not-found failures that are environmental, not product regressions. A clean re-run with no other instance running is needed before treating these as real failures. See `MAC-TESTS` below.
- **iPhone build:** **pass** (`** BUILD SUCCEEDED **`) once built against a real device id. The brief's literal `-destination 'name=iPhone 16 Pro'` first failed with "Unable to find a device matching the provided destination specifier" because that simulator did not exist on this machine (environment, not a code defect).
- **Warnings worth fixing:** 16 warnings total, all in `GrokBot/Voice/VoiceEngine.swift`, 3 distinct:
  - `VoiceEngine.swift:593` — `'allowBluetooth' was deprecated in iOS 8.0: renamed to 'AVAudioSession.CategoryOptions.allowBluetoothHFP'` (deprecated API).
  - `VoiceEngine.swift:421` — `stored property 'finished' of 'Sendable'-conforming class 'SpeechDelegate' is mutable` (concurrency).
  - `VoiceEngine.swift:686` — `'weak' ownership of capture 'self' differs from implicitly-captured strong reference in outer scope` (concurrency / capture).

## Findings

### IOS-01
- **Severity:** broken
- **Platform and screen:** iPhone (all sizes), first-launch onboarding → Sign in, and Settings → Account; light & dark. Reproduced on a fresh install.
- **What's wrong:** On a brand-new install, the sign-in card shows a red error — "Unlock this device's Keychain to restore sign-in." — before the user has done anything. A first-time user has no saved session to "restore," so this reads as a scary failure on the very first screen.
- **Expected:** No error on first run. The keychain-read failure path should distinguish "no saved session yet" (normal, silent) from an actual locked/failed keychain, and only surface a message in the genuine-failure case (and in calmer wording).
- **Suggested fix:** In `CloudAccount.init`, the `catch` at `CloudAccount.swift:47` sets `error` for any throw from `secrets.read(account:"session")`. `KeychainSecretStore.read` already returns `nil` for `errSecItemNotFound` (so true first-run is silent), but other statuses (e.g. `errSecInteractionNotAllowed`, common on the Simulator and possible on device when locked) throw and trip this. Treat "no session present / not yet unlocked" as non-error, or defer the message until the user actually attempts sign-in. At minimum, don't render `account.error` in red on the first paint of onboarding.
- **File:** `GrokBot/Core/CloudAccount.swift:47`; rendered red at `GrokBot/Core/CloudSignInView.swift:46`.
- **Screenshot:** shots/IOS-01.png (see also shots/_ax-signin-scrolled.png, shots/_ios-settings.png)
- **Note:** Most reliably reproduced on the Simulator; please confirm the exact keychain status on a real first-run device. Even if device-only-silent, the wording ("restore") is wrong for someone who never signed in.

### IOS-02
- **Severity:** broken
- **Platform and screen:** iPhone, main "Your Bots, wherever you go" connection-welcome (shown after onboarding when no Mac is paired), largest Dynamic Type (Settings → Accessibility → Larger Text, max).
- **What's wrong:** At the largest text size the title truncates to "Your Bots, w…", the status subtitle to "Sign in to con…", and the primary button label to "Conne…". All three are clipped with ellipses instead of wrapping.
- **Expected:** Title and subtitle wrap to multiple lines; the button grows (or wraps) to fit its full label at accessibility sizes.
- **Suggested fix:** In `connectionWelcome` (`RootView.swift:321`–338) the title `Text("Your Bots, wherever you go").font(.title2…)` and `Text(remote.status).font(.body)` need `.fixedSize(horizontal: false, vertical: true)` (and no implicit `lineLimit(1)`); the "Connect your computer" `Label` button needs to allow multi-line / not be constrained to one line. Consider dropping the title to `.title3` at AX sizes.
- **File:** `GrokBot/Features/RootView.swift:325`–332
- **Screenshot:** shots/IOS-02.png

### IOS-03
- **Severity:** broken
- **Platform and screen:** iPhone, onboarding → Sign in, largest Dynamic Type.
- **What's wrong:** Two problems at the largest text size: (1) the top-right **"Skip"** button renders as **"⋯"** — the label is squeezed into a fixed 44×44 frame and truncates to an ellipsis, so the Skip affordance becomes unrecognizable. (2) The sign-in card is pushed down by the large subtitle and its "Sign in" button visually collides with / sits under the bottom "I'll do this later" button (the card scrolls under the pinned CTA). Content is still reachable by scrolling, but it looks broken.
- **Expected:** "Skip" stays legible at all text sizes; the sign-in card and the bottom CTA don't overlap.
- **Suggested fix:** Remove the fixed `width: 44` on the Skip button (`OnboardingFlow.swift:90`) — give it a flexible width with a minimum tap target, or move Skip into an icon/standard placement. For the overlap, add bottom content inset equal to the pinned button's height, or let the bottom button scroll with the content at AX sizes.
- **File:** `GrokBot/Features/OnboardingFlow.swift:90` (Skip); layout `OnboardingFlow.swift:55`–72, 176–196
- **Screenshot:** shots/IOS-03.png (and shots/_ax-signin-scrolled.png)

### IOS-04
- **Severity:** broken
- **Platform and screen:** iPhone, Create a Bot sheet (reachable once a Mac is paired).
- **What's wrong:** The color the user picks in the color grid is discarded. The `create_bot` command is sent with `color: "purple"` hard-coded, regardless of the selected `color` state. The chosen color only survives inside `appearance`; the top-level `color` field (used elsewhere, e.g. avatar tint fallbacks and the bot list) is always purple.
- **Expected:** The bot is created with the color the user selected.
- **Suggested fix:** Pass the selected `color` state instead of the literal: `RemoteCommand(action: "create_bot", name: cleanName, purpose: purpose, color: color, appearance: appearance)`.
- **File:** `GrokBot/Features/RootView.swift:395`
- **Screenshot:** _(not visually reproduced — needs a paired Mac; found by source review, high confidence)_

### IOS-05
- **Severity:** polish
- **Platform and screen:** iPhone & Mac, app name throughout; first-time-user comprehension.
- **What's wrong:** The product is called three different things. The welcome/onboarding and in-app headings say **"Grok Bot"** (two words); Settings, the sign-in heading, the system permission dialogs, and the bundle display name say **"OpenGrokBot"** (one word); the bundle ids are `org.opengrokbot.ios` / `org.opengrokbot.mac`. A first-time user sees "Grok Bot" on the welcome, then "Allow 'OpenGrokBot'…" in the OS prompt, then "Sign in to OpenGrokBot" in Settings.
- **Expected:** One consistent product name in all user-facing copy.
- **Suggested fix:** Pick one ("OpenGrokBot" matches the bundle/DMG/releases) and use it consistently in the welcome title (`OnboardingFlow.swift:40`, `MacSetupView.swift:37`), step titles, and headings. If "Grok Bot" is the intended brand, change the Settings/sign-in strings instead.
- **File:** `GrokBot/Features/OnboardingFlow.swift:40`; `GrokBotMac/Features/MacSetupView.swift:37`; vs. `GrokBot/Features/SettingsView.swift:13`, `GrokBot/Core/CloudSignInView.swift:26`
- **Screenshot:** (screenshot removed: personal details), shots/_ios-settings.png

### IOS-06
- **Severity:** polish
- **Platform and screen:** iPhone, default appearance on first launch.
- **What's wrong:** The iOS app forces **light mode** on first launch regardless of the device's system setting — the `appearance` default is `"light"`, applied via `.preferredColorScheme(.light)`. A user whose phone is in dark mode gets a light app until they find Settings → Appearance. (The Mac app defaults to `"dark"`, so the two platforms also disagree.)
- **Expected:** Default to "Follow system" so the app matches the user's device, unless there's a deliberate brand reason to force light.
- **Suggested fix:** Change the default to `"system"` in `GrokBotApp.swift:10` and `SettingsView.swift:6` (the picker already offers Follow system / Dark / Light). Decide whether Mac should match.
- **File:** `GrokBot/App/GrokBotApp.swift:10` and `:24`; `GrokBot/Features/SettingsView.swift:6`
- **Screenshot:** shots/_probe-welcome-dark.png (dark renders correctly once chosen)

### IOS-07
- **Severity:** polish
- **Platform and screen:** iPhone, onboarding → Pair / Microphone / Notifications steps.
- **What's wrong:** On the Pair, Microphone, and Notifications steps there is a large band of empty space between the subtitle (top third) and the bottom button, with the content hugging the top. It reads as unfinished rather than deliberate.
- **Expected:** Content vertically balanced (centered) or the hero/illustration allowed to fill some of the gap, as the welcome does.
- **Suggested fix:** In `OnboardingFlow.page` add a `Spacer()` to center the hero+title+subtitle block, or increase top padding less and let the `ScrollView` content center.
- **File:** `GrokBot/Features/OnboardingFlow.swift:55`–73
- **Screenshot:** _(see the Pair/Mic/Notifications captures in the walk-through; no single finding shot)_

### MAC-01
- **Severity:** polish
- **Platform and screen:** Mac, voice mode (full screen), first use.
- **What's wrong:** On first entry to voice mode the bottom shows "Downloading the speaking model… 100%" in orange while the on-device Kokoro TTS model downloads. It's informative, but it lingers at "100%" and the orange styling reads like a warning. First-time users get a multi-second wait with no size/ETA context before the bot can speak.
- **Expected:** A calmer "Setting up the voice…" state (neutral color), ideally with a one-time note that the first voice use downloads a model, and a clear finish.
- **Suggested fix:** Use a neutral/secondary color for the progress line rather than orange (orange elsewhere signals errors — `VoiceUI captions` use orange for `session.message`), and collapse the "100%" state promptly once ready.
- **File:** `GrokBot/Voice/VoiceUI.swift` captions (`session.message` path, ~`:183`–185) and the Mac local-voice download surface.
- **Screenshot:** shots/MAC-01.png (= shots/_mac-voice-full.png)

### MAC-02
- **Severity:** polish
- **Platform and screen:** Mac, setup step 3 (Install).
- **What's wrong:** The detected CLI path wraps across 4 lines of monospace under "Already installed." With the test fixture it's a very long DerivedData path; a real install (`/usr/local/bin/codex`) is short, so this is mostly a long-path presentation issue. Still, long paths aren't truncated/middle-elided and can dominate the card.
- **Expected:** Middle-truncate or scroll long paths so they occupy one or two lines.
- **Suggested fix:** Use `.lineLimit(2)` with `.truncationMode(.middle)` for the path `Text` in `MacSetupView.install`.
- **File:** `GrokBotMac/Features/MacSetupView.swift:149`
- **Screenshot:** (screenshot removed: personal details) (= (screenshot removed: personal details))

### MAC-03
- **Severity:** polish
- **Platform and screen:** Mac, Connect apps / Composio (setup step 5).
- **What's wrong:** The header says "5 of 5 apps connected" while Slack in the same list shows an "Add" button (not connected), and Google Calendar + Google Drive each appear twice (once under "Recommended for you" and once under "Productivity"). The count and the per-row state can disagree, and the duplication looks like a bug even though it's category grouping.
- **Expected:** The connected count matches the visible connected rows; or clarify the count's scope. Consider de-duplicating apps that fall into two categories, or label the sections so the repeat is clearly intentional.
- **Suggested fix:** Recompute the "N of M connected" string from the same set that renders the rows, and dedupe apps across the Recommended/category sections (or show a single list).
- **File:** `GrokBotMac/Composio/MacComposioSetupView.swift` (Composio setup list) and `GrokBotMac/Features/MacSettingsView.swift` MacHeadsUpSources for the connected logic.
- **Screenshot:** (screenshot removed: personal details)

### MAC-04
- **Severity:** polish
- **Platform and screen:** Mac, release packaging (DMG) and app signing — release-readiness.
- **What's wrong:** Two 10.0-release concerns. (1) The app/DMG are **not notarized and only ad-hoc signed** (`Signature=adhoc`, `TeamIdentifier=not set`), so a user opening the public DMG will hit Gatekeeper's "unidentified developer" block. (2) `hdiutil` prints two deprecation warnings during the DMG build (`hdiutil create`/`convert` … deprecated), harmless now but worth updating.
- **Expected:** For a public release, a Developer ID-signed, notarized, stapled app and DMG.
- **Suggested fix:** Sign with a Developer ID identity (`MACOS_SIGN_IDENTITY`) and add a notarize + staple step to `scripts/build-macos.sh`. Optionally migrate off the deprecated `hdiutil` subcommands. (The script already supports an identity override; this is a release-process note, not a code bug.)
- **File:** `scripts/build-macos.sh`
- **Screenshot:** shots/MAC-03.png (DMG window renders correctly — see "look good")

### REL-01
- **Severity:** broken (release blocker)
- **Platform and screen:** iPhone + Mac, version string everywhere.
- **What's wrong:** This is the **10.0** release but the marketing version is still **0.9.9** everywhere: `CFBundleShortVersionString` in both built apps, the DMG filename (`OpenGrokBot-0.9.9-mac-universal.dmg`), the Mac Settings sidebar ("OpenGrokBot 0.9.9"), Settings → Updates, and `MARKETING_VERSION = "0.9.9"` across the Xcode project.
- **Expected:** Version bumped to 10.0 (and build number incremented) before release.
- **Suggested fix:** Set `MARKETING_VERSION = 10.0` for all targets in `GrokBot.xcodeproj/project.pbxproj` (6 occurrences), rebuild.
- **File:** `GrokBot.xcodeproj/project.pbxproj:387, 410, 833, 860, 2238, 2262`
- **Screenshot:** (screenshot removed: personal details)

### MAC-TESTS
- **Severity:** broken (needs confirmation)
- **Platform and screen:** Mac, automated UI test suite.
- **What's wrong:** Both `GrokBotMacUITests` cases failed (see Build and tests). The earliest failures — a shift+Return newline in the draft (`:41`) and finding `bot-model-id-codex` (`:50`) — could be real regressions in the chat composer / bot-details inspector, **or** artifacts of the test running next to a second same-bundle-id instance of the app. The unit suite (`GrokBotMacTests`) did not execute any cases, which itself is worth checking (empty target or mis-wired scheme).
- **Expected:** Green UI suite on a clean run; unit suite actually runs its cases.
- **Suggested fix:** Re-run `xcodebuild … -scheme GrokBotMac … test` with no other OpenGrokBot instance running and triage the real failures; verify `GrokBotMacTests` has cases and is included.
- **File:** `GrokBotMacUITests/MacUITests.swift:41, 50, 96, 106`
- **Screenshot:** _(logs: the Mac test log (not published))_

## Things that already look good
_(So they don't get changed by accident.)_

- **iOS permission dialogs** — the Speech Recognition and Microphone prompts have clear, specific custom usage strings ("…to turn what you say into messages for your Bots", "…for hands-free voice conversations with your Bots"). (shots not needed)
- **iOS onboarding progress + Reduce Motion** — the step dots are correct, and Reduce Motion is handled throughout (hero bob/scale animations are guarded, transitions become fades). Verified in source across `OnboardingFlow`, `MacSetupView`, `VoiceUI`, `MacCallPill`.
- **iOS welcome, light & dark** — renders cleanly on 16 Pro, SE, and 18 Pro, both themes. (shots/_probe-welcome-dark.png, shots/_probe-se-welcome-light.png, shots/_probe-16pro-2.png)
- **Mac first-run setup (all 6 steps)** — polished, consistent, good copy; the sign-in step correctly gates Continue until the CLI check passes. ((screenshots removed: personal details))
- **Mac main window & chat** — clean sidebar/empty-state, labeled controls (Search Bots, New Bot, Settings, Dictate, Start voice mode), working send/reply. ((screenshot removed: personal details), (screenshot removed: personal details))
- **Mac voice mode** — orb state transitions (Thinking/Listening) are clear, orb has a correct VoiceOver label, waveform is decorative/hidden. (shots/_mac-voice-full.png)
- **Mac call pill** — appears in the menu-bar/notch region when the app isn't frontmost, with bot face + running timer + "Open Grok Bot" label. (shots/_mac-callpill.png)
- **Mac command palette (⌘K)** — tidy Spotlight-style search with icons and subtitles (Bots, New Bot, Computers, Settings, Keyboard shortcuts, Copy diagnostics). ((screenshot removed: personal details))
- **Mac Settings (11 tabs)** — consistent card layout, good explanatory copy, secure fields for API keys with billing warnings, usage dashboard. ((screenshots removed: personal details))
- **DMG** — correct drag-to-Applications window with custom background, arrow, app icon, Applications symlink; universal (arm64 + x86_64); hardened runtime. (shots/_mac-dmg.png)
- **VoiceOver labels** — broadly present and meaningful across both platforms (buttons announce their action; decorative art and waveforms are `accessibilityHidden`).

## Couldn't check
- **iPhone roster (Bot list), a chat, and voice mode (on device)** — these require a **paired Mac** (`remote.hasSnapshot`), which a Simulator can't establish without a live desktop connection. Walked their source thoroughly instead; IOS-04 was found that way. The equivalents were exercised on the Mac app directly.
- **iOS CallKit / Dynamic Island / Lock-Screen call controls** — the "call keeps going after you leave the app" Live Activity and CallKit mute/end need a real iPhone; not testable in the Simulator.
- **The exact iPhone 16 Pro / iPhone SE (3rd gen) interactive walk-through** — those device types were created and the app installed+launched on both (welcome verified on SE and 16 Pro), but the full tap-through used iPhone 18 Pro because the 16 Pro/SE simulator-control access grant was stuck in a cooldown during the session. Same binary and Pro-class geometry; findings apply across them.
- **Mac call-pill hover-expand (mute/end), and clicking the Bot face to return** — the compact pill was captured, but hover-to-expand can't be driven reliably through background automation. Behavior confirmed by source (`MacCallPill.swift`: hover expands to a 70pt panel with mute + end; the face button calls `openApp()`).
- **Reduce Motion, VoiceOver rotor, and full large-text sweep on the Mac app** — spot-checked in source and on key iOS screens; not exhaustively re-walked on every Mac screen.
- **Real sign-in / pairing flows** — not exercised with live credentials (the audit avoided touching the user's real account; the user's real account was only ever read, never modified).
