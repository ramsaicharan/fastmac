## What does this change?

<!-- One or two sentences. Link the issue it addresses, if any. -->

## How was it checked?

- [ ] `--checkall`, `--navigation-check` and `--render-check` pass locally
- [ ] UI changes: before/after render images attached (light and dark)
- [ ] New behaviour has a check in the matching `*SelfCheck.swift`

## House rules

- [ ] Any removal goes through `AppStore.stage` / `Safety.canDelete` and moves to the Trash
- [ ] No new network requests, telemetry or third-party dependencies
- [ ] Copy says only what the measurements support
