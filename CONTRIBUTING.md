# Contributing to Glimpr

Thanks for your interest!

## Dev setup

- Flutter 3.44 / Dart 3.12
- macOS: Xcode 26 — `flutter build macos --debug`
- Windows: VS 2022 Build Tools (C++ workload) — `flutter build windows --debug`
  (the runner C++ compiles with warnings-as-errors; keep it ASCII-safe)

## Before you open a PR

```
flutter analyze
flutter test
```

Both must be clean. CI runs the same gates on macOS and Windows.

## About `packages/glimpr_pro`

The public repo always builds the complete FREE tier. `packages/glimpr_pro`
is a no-op stub package by design; a possible future paid tier lives outside
this repo. Please don't send PRs that modify the stub's contract.

## Code style

Match the surrounding code. The repo intentionally does not run
`dart format` (it predates the current formatter style). Code comments are
in English; user-facing strings go through the ARB files (`lib/l10n/`) in
both English and Traditional Chinese.
