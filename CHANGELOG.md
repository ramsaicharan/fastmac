# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org).

## 2.1.0 — storage watch

- **Storage watch.** FastMac now watches *how fast* storage is filling and *where*, not just
  how much is free. The menu bar popup stays quiet until something needs attention, then
  shows at most two cards — each with its evidence, its size and a risk label:
  - **Filling fast** — a projection from the last three days of free-space readings, such as
    "less than 5 GB will be left within a day". Ordinary daily wobble raises nothing.
  - **Leftover browser test profiles** — headless-Chrome profiles that automated test runs
    left in the temp folder. One click moves the idle ones to the Trash. A profile a browser
    still holds, or one touched in the last 30 minutes, is never included.
  - **Caches that grew back** — Chrome, HyperFrames, npm, pip, Homebrew, Yarn and pnpm,
    Gradle and Xcode DerivedData, measured once a day. Clearing waits until the owning app
    is closed.
  - **Large apps unused for months**, and a **reminder to rescan** that names the folder that
    grew between your last two scans.

  It never scans your documents and never removes anything on its own. Readings are light:
  every 30 minutes, one free-space reading and a single listing of the temp folder (about
  80 ms); once a day, a fixed list of cache folders at background priority. It can be turned
  off in Settings → Storage watch. Optional notifications cover filling fast, leftover
  profiles and fast-growing caches, once per rise.

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
