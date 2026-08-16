# Roadmap

Shipped recently: native Settings window, opt-in searchable dictation
history, per-app profiles (`profileOverrides`), one-click "Auto-send in
this app" menu toggle, tag-triggered GitHub releases, CI on macOS 26.

## Next

- **Notarized distribution.** Requires an Apple Developer ID ($99/yr).
  Once available: Developer ID signing + notarization in the release
  workflow, so downloads run without the quarantine dance. Until then,
  releases are unsigned zips.
- **Homebrew tap.** A `homebrew-tap` repo with a cask, once this
  repository is public (private repos can't serve public formulas).
- **Settings UI for per-app profiles.** The engine understands
  `profileOverrides` (per-bundle-prefix `commitDelay` / `autoReturn`);
  today it's configured via `defaults write`. A profiles table in
  Settings is the natural next step.
- **Optional Whisper backend.** Apple's on-device engine is the default
  and the right one for streaming latency, but an optional local Whisper
  path would raise the accuracy ceiling on noisy audio and technical
  vocabulary, widen language coverage beyond two parallel engines, and
  allow true mid-sentence code-switching. Big lift: bundling an inference
  runtime, model management, and a different streaming model — deliberately
  not rushed.
- **More than two parallel languages.** The per-utterance confidence pick
  generalizes; the open questions are CPU cost and commit-latency
  coordination across three or more engines.
