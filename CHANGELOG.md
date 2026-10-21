# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org).

## 2.0.0 — first public release

FastMac is now open source under the MIT license.

- **Whole-Mac scanning.** Scan the entire startup disk, not just your home folder. The walk
  skips macOS's mirror of the data volume and every other mount, so each byte counts once.
- **Disk overview.** Every scan is shown against the whole disk: scanned, macOS volumes,
  couldn't read, and free, with purgeable space noted.
- **Guided Full Disk Access.** Before a whole-Mac scan, FastMac explains what it can't see,
  opens Privacy & Security → Full Disk Access, offers its icon to drag into the list, notices
  when access is granted and offers a rescan — including after "Quit & Reopen".
- **New look.** A shared design system (spacing, type, colour, motion) with a redesigned
  Mac Health dashboard and menu bar popup, including a frosted panel and animated readings.
- **Command-line tools** renamed to `fastmac` and `mactidy`, with state in `~/.fastmac/cli`.
- Fixed quick wins not being found when a scan starts at `/`.
