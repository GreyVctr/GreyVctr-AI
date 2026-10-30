# iOS 27 validation baseline

## Device performance

The iOS 27 device list was checked on 2026-10-30. No physical iPhone or iPad was online, so memory, energy, and thermal measurements remain pending. Run Instruments on a physical device with the production model installed:

1. Record launch and model initialization with Time Profiler and Allocations.
2. Record a ten-turn text chat, one image prompt, and a model update. Note peak resident memory, hangs, and thermal state.
3. Background during generation, return to the app, and repeat after switching CPU/GPU preference. Check cancellation and engine reload.
4. Compare the same scenarios after any performance change. Simulator measurements are not a substitute for device measurements.

## Concurrency migration

The app and local LiteRT-LM package currently use Swift 5.9 language mode. A diagnostic iOS Simulator build with `SWIFT_STRICT_CONCURRENCY=complete` succeeded on 2026-10-30 but emitted warnings in both modules. The vendored SDK's mutable `ExperimentalFlags` statics and stream callback captures are among them; app warnings include values crossing the `Engine` actor boundary. Resolve these in a separate SDK-aware pass before making complete checking or Swift 6 mode the default. Avoid changing vendored code solely to silence warnings without confirming its synchronization contract.

Diagnostic command:

```sh
xcodebuild -quiet -project GreyVctrAI/GreyVctrAI.xcodeproj -scheme GreyVctrAI -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete
```

## Accessibility device pass

Test AI Chat, Chat with Skills, Ask Image, and model download at the largest Dynamic Type sizes with VoiceOver. Confirm composer controls remain reachable, messages read in order, progress is understandable, and expanded thinking content can be found and collapsed.
