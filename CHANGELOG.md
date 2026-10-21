# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org).

## 2.0.0 — first public release

DiskMap is now **FastMac**, released under the MIT license.

- **Whole-Mac scanning.** Scan the entire startup disk, not just your home folder. The walk
  skips macOS's mirror of the data volume and every other mount, so each byte counts once.
- **Disk overview.** Every scan is shown against the whole disk: scanned, macOS volumes,
  couldn't read, and free, with purgeable space noted.
- **Guided Full Disk Access.** Before a whole-Mac scan, FastMac explains what it can't see,
  opens Privacy & Security → Full Disk Access, offers its icon to drag into the list, notices
  when access is granted and offers a rescan — including after "Quit & Reopen".
- **New look.** A shared design system (spacing, type, colour, motion) with a redesigned
  Mac Health dashboard and menu bar popup, including a frosted panel and animated readings.
- **Migration from DiskMap.** Settings, cleanup queue, scan history and activity history carry
  over on first launch. Startup items disabled by DiskMap stay restorable.
- Fixed quick wins not being found when a scan starts at `/`.

## 1.x — DiskMap (private)

Native menu bar app with Mac Health, quick actions, activity history and alerts, AI storage,
eight storage views, a reviewed cleanup queue, startup items, maintenance and admin tools.
