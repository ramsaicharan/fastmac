# Command-line tools

FastMac started as two terminal tools. They still work and need nothing beyond what ships
with macOS: Python 3's standard library, Bash and vanilla JavaScript for the report. No pip
installs, no CDN, no account.

```bash
cli/fastmac scan ~ --apps --dupes     # scan, analyse, open the report
cli/fastmac serve                     # same report, but live: delete from the UI + RAM monitor
cli/fastmac mem                       # memory report in the terminal
cli/mactidy help                      # memory reporting and one-shot cache cleaning
```

The command-line tools keep their own state in `~/.fastmac/cli` and `~/.mactidy`. The FastMac app
uses `~/.fastmac`.

Run the tests with:

```bash
cd cli && python3 -m unittest test_fastmac
```

## The eight views

One scan, eight ways to read it. Open with `fastmac scan` or `fastmac ui`.

| View | What it shows |
|---|---|
| **Folders** | Browse folder by folder, sized as you go, with share-of-parent bars |
| **Sunburst** | Rings radiating out from the scan root; click the centre to go up |
| **Flame** | Depth top to bottom, size left to right |
| **Bubbles** | Nested bubbles, one per folder, two levels deep |
| **Mind Map** | Branches from the root, sized by weight |
| **Top Sizes** | The 300 biggest items anywhere under the current folder, ranked |
| **Age Map** | Where your bytes sit on a timeline, plus Big & Untouched |
| **Treemap** | Every folder as a rectangle, squarified, sized by bytes |

Plus four more tabs: **Quick Wins**, **Duplicates**, **Apps**, and **Memory**.

Click anything to inspect it; click a folder to drill in. `Esc` or `Backspace` goes up,
number keys `1`–`9` switch views.

## Selecting and removing from the UI

A saved report is a static HTML file — it can read nothing and change nothing. To act from
the browser, run the report from a local process instead:

```bash
cli/fastmac serve
```

The header badge turns green (**live**). Now:

- **Tick the checkbox** on any row in Folders or Top Sizes, or **⌘-click / Ctrl-click** any
  tile, arc, bubble or rectangle in the graphical views. A bar appears at the bottom with the
  running count and total.
- **Add to cleanup queue** stages the selection. The queue lives in the server process, so it
  is the very same queue `fastmac queue` shows in your terminal.
- The sidebar then offers **Move to Trash**, behind a confirmation listing exactly what will go.
- **Reveal in Finder** opens any item in place.

Bulk actions where they make sense: stage every extra duplicate copy, stage all Big & Untouched
files, uninstall an app with all its leftovers, stage a whole Quick Wins category.

### How the live server is locked down

It can delete files, so it is deliberately narrow:

- Binds `127.0.0.1` only — never a routable interface.
- Every page and `/api/` call needs a random per-session token. The launch URL carries it in the
  fragment plus a one-time query parameter; the server exchanges that query for a strict,
  same-site cookie, and the page moves the fragment into `sessionStorage` before stripping it
  from the address bar. Subsequent API calls also send the token header.
- The `Host` header is pinned to loopback, which blocks DNS-rebinding attacks.
- **Every path is re-validated server-side.** The same guard that protects the CLI runs again on
  every stage and every purge; a client asking to delete `/System/Library` is refused regardless
  of what the page believes.
- Moving still defaults to the Trash, and still needs an explicit confirmation.
- The server exits with Ctrl-C; the staged queue is persisted in ~/.fastmac/cli/queue.json.

## Memory monitor

The **Memory** tab (live mode only) polls every 2 seconds while that tab is visible and shows:

- **In use / pressure / compressor ratio / swap** as four headline figures
- The app / wired / compressed / free split as one stacked bar
- A rolling area chart of the last few minutes, with swap overlaid as a dashed line
- **Top consumers grouped by application**, with process counts

RAM sampling uses macOS kernel/process APIs; it does not scan your home folder or read the disk map.

The process count matters as much as the megabytes. Resident size double-counts framework pages
shared between an app's helper processes, so the column sums to more than real usage — but a
Chromium-based app running 50 processes is telling you something true.

Terminal equivalent: `cli/fastmac mem`.

## Commands

```
fastmac scan [path]          scan and open the report        --apps --dupes --no-ui --serve
fastmac serve [name]         serve it live — delete from the UI, watch RAM   --port N
fastmac mem                  memory report in the terminal
fastmac ui [name]            rebuild the static report for a snapshot
fastmac snapshots            list saved scans
fastmac diff <old> <new>     compare two snapshots — what grew while you weren't looking
fastmac dupes [path]         find duplicates by content      --stage
fastmac apps                 application footprints + orphaned data
fastmac uninstall <name>     stage an app and everything it scattered
fastmac builds [paths...]    find stale build artifacts      --age 60 --stage
fastmac inspect <path>       detailed breakdown of one path
fastmac stage <paths...>     add to the cleanup queue
fastmac queue                review what is staged
fastmac unstage [n...]       remove from the queue           --all
fastmac purge                dry run                         --apply (moves to Trash)
fastmac watch                live free-space monitor
```

## What each analysis does

**Quick Wins** — Downloads, caches, logs, iOS simulators, Xcode DerivedData, npm/pnpm/Yarn/pip/
Gradle/CocoaPods/Homebrew/Go/Cargo caches and Docker data, scoped to the selected scan root and
reported as unique reclaimable space. Each is tiered `safe` (regenerates on its own) or `review`
(holds real data).

**Age Map** — every file 50 MB or larger, bucketed by last-modified date. *Big & Untouched*
surfaces files over 100 MB you haven't modified in a year; stage the whole set in one click.

**Duplicates** — byte-for-byte. Files are grouped by exact size, then by a digest of the first
64 KB, then by a full BLAKE2b digest. Same name is never enough; same content is.

**Apps** — every application's true footprint: the bundle plus the caches, preferences,
containers, group containers, HTTP storage, saved state, WebKit data and logs it scattered
across your Library. `uninstall` stages the whole set, not just the icon you'd drag to the Trash.
Apps bundling their own copy of Chromium are marked `electron`.

**Orphaned data** — Library folders over 100 MB whose owning application is no longer installed.

**Snapshots** — scans are saved as gzipped JSON in `~/.fastmac/cli/scans/`; the rolling retention
window keeps the latest 12. `diff` holds two against each other and reports what grew, shrank,
appeared and vanished.

**Inspector** — for any selection: size on disk versus logical size, the sparse/compressed gap,
file and folder counts, share of parent, modified date, and a ranked list of the largest items inside.

## Safety

Nothing is deleted during a scan. Ever. Findings go to a **staged cleanup queue** that you
review before anything happens.

- `purge` is a dry run. `--apply` is required to act.
- `--apply` **moves items to the Trash**, so they stay recoverable. Permanent deletion is disabled.
- Volume space is reclaimed only after you empty the Trash in Finder.
- Hard-linked files are excluded from duplicate/reclaimable totals and cannot be staged, because
  moving one name would not reclaim the shared blocks.
- Staging is refused for: any path outside `$HOME`, `/Applications` and `/Volumes`; anything
  under `/System`, `/usr`, `/bin`, `/sbin`, `/private/var/db`, `/Library/Apple`, `/dev`;
  and `$HOME` itself plus `Documents`, `Downloads`, `Desktop`, `Library`, `Pictures`,
  `Movies`, `Music`, `.ssh`, `Applications`, and the existing Trash.
- Recent moves are recorded in the bounded `~/.fastmac/cli/cleanup.log` audit log with timestamp and size.
- `scan`, `ui`, `diff`, `inspect`, `apps`, `dupes`, `builds` and `watch` are all read-only.

## Privacy

Everything runs on your machine. Scanning, hashing and duplicate matching are local; the report
is a single self-contained HTML file with no external requests — no CDN scripts, no fonts, no
analytics. The tool has no reason to talk to a server and doesn't.

## Performance

Roughly **2.16 million files in 52 seconds** on this Mac (M-series, 10 cores, 199 GB home
folder). The walk is threaded — `os.scandir` releases the GIL during syscalls — so threads help
despite this being Python. Tune with `--workers`; concurrency is capped at 8 to avoid retaining
excessive thread stacks and directory state.

The report keeps the tree pruned: items under 1 MB are rolled into a "smaller items" bucket,
at most 60 children per folder, 12 levels deep. That keeps a 2 M file scan to a ~3.7 MB page
that renders instantly.

## Where things live

```
~/.fastmac/cli/scans/<name>.json.gz    saved scans
~/.fastmac/cli/report-<name>.html      generated reports
~/.fastmac/cli/queue.json              the staged cleanup queue
~/.fastmac/cli/cleanup.log             bounded record of recent Trash moves
```

## Files

| File | |
|---|---|
| `fastmac` | CLI |
| `fastmac_core.py` | scanner, analysis, duplicates, app footprints, queue, safety guard |
| `fastmac_report.py` | HTML report — CSS, the eight layout algorithms, interaction |
| `fastmac_serve.py` | loopback API server: staging, purging, live memory |
| `fastmac_mem.py` | memory sampling — vm_stat, swap, per-app process grouping |
| `mactidy` | bash tool: memory reporting and one-shot cache cleaning |

## Performance note

`scan` stores its analysis inside the snapshot, so `serve` and `ui` reopen it in well under a
second rather than re-walking your caches. Scans taken before this existed are recomputed once.
The app keeps a rolling window of 12 snapshots and caps the cleanup queue at 5,000
identity-checked items so its own state stays small.

## Known limits

- The Trash and some Library subfolders report 0 B without Full Disk Access
  (System Settings → Privacy & Security → Full Disk Access → add your terminal).
- "Sparse + compressed" in the inspector is logical size minus allocated blocks. On a dev
  machine that gap is mostly **sparse files** — disk images, qcow2 VM volumes — not APFS
  compression. It is not reclaimable space.
- `uninstall` matches Library data by bundle identifier and app name. An app that stores data
  under an unrelated name won't be fully matched; check the staged list before purging.
- The Memory tab needs `fastmac serve`. A saved report file cannot read live memory, and says so.
- Live mode is one tab at a time by design: each `serve` mints a fresh token, so an older tab
  goes read-only and tells you why.
