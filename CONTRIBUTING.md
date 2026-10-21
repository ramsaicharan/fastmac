# Contributing to FastMac

Thanks for helping. Bug reports, ideas, docs fixes and pull requests are all welcome.

Anyone can contribute: fork the repository, make your change on a branch, and open a pull
request. Automated checks run on every pull request, and a maintainer reviews it before
merging. For larger changes, open an issue first so we can agree on the approach.

Be kind and constructive in issues and reviews. Harassment or personal attacks aren't welcome.

## Build and run

You need macOS 14 or later and Xcode 16 (or a Swift 6 toolchain). There are no other
dependencies.

```bash
git clone https://github.com/<you>/fastmac.git
cd fastmac
swift build -c release            # compile
scripts/bundle.sh                 # build/FastMac.app, signed ad hoc
open build/FastMac.app
```

The bundled app is what you want for anything involving the menu bar, permissions or
windows. For quick iteration, the bare binary runs the same checks headlessly:

```bash
BIN="$(swift build -c release --show-bin-path)/FastMac"
"$BIN" --checkall
```

> **Testing tip:** always test the real `FastMac.app`. Don't make renamed copies with a
> different bundle identifier — each one becomes a separate entry in macOS privacy settings.
> Ad-hoc builds can lose a Full Disk Access grant after a rebuild; re-enable it in
> System Settings if a check needs it.

## Run the checks

Every pull request must keep these green. CI runs them on macOS.

```bash
"$BIN" --checkall                         # 700+ feature checks
"$BIN" --navigation-check                 # every route and sidebar item
"$BIN" --render-check                     # core views render
"$BIN" --health-render-check  /tmp/fastmac-health
"$BIN" --quick-actions-render-check /tmp/fastmac-popup
"$BIN" --feature-render-check /tmp/fastmac-features
"$BIN" --menu-check /tmp/fastmac-menu
(cd cli && python3 -m unittest test_fastmac)
```

Render checks write PNGs you can open to review a UI change in light and dark mode. They
use fixture data only — no real apps, files or processes. `ImageRenderer` can't draw native
AppKit-backed controls (bordered buttons, pickers); those appear as yellow placeholders, so
prefer the design-system button styles in new UI.

Feature areas also have their own flags, such as `--disk-overview-check`, `--startup-check` and `--perf-check`; see `Sources/FastMac/main.swift`.

## Project layout

```
Sources/FastMac/       the app (SwiftUI + AppKit), one feature per file
  *SelfCheck.swift     headless checks for each feature
  DesignSystem.swift   spacing, type, colour, motion and shared components
  Analysis.swift       Safety.canDelete — the single gate for every removal
Fixtures/              helper programs used by native checks
scripts/bundle.sh      builds, icons, signs and packages FastMac.app
cli/                   the original Python/Bash command-line tools
docs/                  app guide and README screenshots
```

## House rules

These keep FastMac trustworthy. Pull requests that break them won't be merged.

1. **Every removal goes through the safety guard.** Stage paths with `AppStore.stage`, which
   calls `Safety.canDelete`; never remove files directly. Removal means *move to the Trash* —
   no permanent deletion.
2. **Act on exactly what the user confirmed.** Process actions re-verify identity (PID, start
   time, path) before quitting. Admin commands show the exact command first.
3. **No telemetry and no internet.** The only network requests are to `127.0.0.1`.
4. **No third-party runtime dependencies.** Apple frameworks only.
5. **Say only what the measurements support.** Copy shouldn't promise speed-ups, freed memory
   or reclaimed space the app can't guarantee. Unknown readings stay "unavailable", not zero.
6. **Ask for permissions only when a feature needs them**, and keep features working without.

## Code style

- Match the surrounding code: naming, comment density and idiom. Comments explain *why*.
- UI uses the design system: `DS.Space`, `DS.Radius`, `DS.Palette`, the `Font.ds*` styles,
  `DSButtonStyle` and `DSCardButtonStyle`. Don't add literal sizes or colours.
- New behaviour gets a check in the matching `*SelfCheck.swift`, registered in `main.swift`
  and included in `--checkall`.
- Keep pull requests focused on one change. Include before/after render images for UI changes.

## Updating README screenshots

```bash
"$BIN" --readme-screenshots /tmp/fastmac-shots
```

This renders Retina images from fixture data. Copy the ones you need into `docs/screenshots/`.

## Releases (maintainers)

1. Update `CHANGELOG.md` and the default `FASTMAC_VERSION` in `scripts/bundle.sh`.
2. Tag the commit: `git tag v2.1.0 && git push origin v2.1.0`.
3. The release workflow builds `FastMac-2.1.0.zip`, publishes its SHA-256 and creates the
   GitHub release.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
