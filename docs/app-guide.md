# FastMac app guide

Detailed behaviour, measurements, permissions and limits of the native app. Start with the
[README](../README.md) for installation and an overview.

A native macOS menu bar app for understanding storage and performance, built with SwiftUI
and AppKit. Every implemented feature is free, with no account, subscription, feature gates,
third-party runtime dependencies or telemetry.

```bash
scripts/bundle.sh
open build/FastMac.app
```

Requires macOS 14 or later and a Swift 6 toolchain to build. The local bundle is ad-hoc signed;
public distribution still needs Developer ID signing and notarization.

Version 1.6 corrects cleanup risk and makes helper ownership visible. Ordinary files are
labelled **Caution** when moved to Trash. Known Codex/Claude transcript stores and their
ancestors are protected at both staging and execution, including entries saved by an older
version. The inspector explains the history-loss consequence and links to AI Storage.

AI Storage now measures `~/.codex/sessions`, `~/.codex/archived_sessions` and
`~/.claude/projects` using file metadata only. It keeps the largest 20 JSONL files per source,
with sizes and modification dates, while measuring the full bounded tree. It never opens
messages/images, rewrites transcripts or suggests history as cache cleanup. Review and
back up needed conversations before deleting them in their owning app. Archiving retains
history and does not reclaim that disk storage. Custom transcript roots are not discovered.

In **Performance**, select an app name for its helper breakdown: role, count, number waiting,
recent CPU and accounted memory footprint. The detail is a timestamped snapshot. Waiting is
a kernel state, not proof that a helper is unused or that an AI task is running. Use **Open app**
to review finished chats, or confirm **Quit app…** for a normal app-level quit. No automatic
helper killing, suspension or restart is added. Process details explain Node runtimes and
renderers. The existing Projects → Agent sessions observer can review descendants that
survive an observed agent exit; those still need individual review.

Claude's embedded coding executable joins its desktop total only when the current readable
parent chain reaches that desktop process, under the same user and with consistent start
times. Standalone/terminal-launched coding instances remain separate. Memory, Performance,
the menu popup and new activity samples use this association. Older history keeps its
original grouping; old and new Claude totals therefore have different coverage. A new
monitoring session breaks chart/alert continuity on relaunch. Sizes using powers of 1024
now say KiB/MiB/GiB explicitly. `--helpers-check` exercises the new protections and grouping.

Version 1.5 adds per-app history rankings, resident-memory and accounted-footprint
charts, average and observed peak memory, CPU trends, and inspection of a selected
app's memory peak. The same background sampler now records compressed RAM and
swap-in/swap-out rates; system history also exposes pressure, free storage, CPU,
GPU, thermal state, battery and disk/network I/O. No additional polling timer or
background service is added.

Select **Activity History**, choose the time range, then select an app. Resident
history remains available from older logs. Footprint and swap-rate recording starts
with this version; old app CPU values without a declared scale and validated timebase are excluded from
comparisons. Rankings use the displayed samples, which may be downsampled for large
ranges. They are not continuous averages, guaranteed peaks or proof of a memory leak.

`build/FastMac.app/Contents/MacOS/FastMac --diagnose-apps 60` prints a bounded, read-only
JSON capture of AI-app groups, helper roles, CPU, RSS, footprint, pressure and swap
activity. This explicit capture does not start history recording or inspect command
arguments. The new fixture checks run with `--activity-trends-check`.

### Local signing and remembered permissions

The bundle script defaults to ad-hoc signing for local development. To use an existing valid
code-signing certificate and its private key, select its exact name or SHA-1:

```bash
security find-identity -v -p codesigning
FASTMAC_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/bundle.sh
```

An unavailable or ambiguous requested identity stops packaging before the build; the script
never silently falls back to ad-hoc signing. It creates no certificate and changes no trust
or macOS permission setting. Keep the bundle identifier and signing identity consistent
between builds. This does not perform notarization.

macOS uses code identity when remembering privacy choices. An ad-hoc designated requirement
is tied to that particular build, so replacing it with changed code can require permission
again. A normal relaunch of the same unchanged app is a different case. See
[Apple TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/).

Onboarding is acknowledged when first displayed. Opening onboarding or Settings does not
probe protected folders; **Check Access** and **Recheck Access** explicitly run the best-effort
Full Disk Access check. Unchecked and indeterminate results are distinct from denied access.

## Menu bar and monitoring

FastMac starts in the menu bar. Its text and template symbols follow the current light/dark
menu appearance. Settings selects a compact health, CPU, memory, download-rate or free-storage
readout. Clicking the icon opens a quick-action popup with memory, CPU and storage summaries,
open apps sorted by memory or CPU, and direct links to the dashboard and storage review.
Right-click opens the traditional menu, including **Quit FastMac**.

Use **Quit…** beside an app to review and confirm a normal quit. The small stop icon beside it
opens **Force Quit…**, with an explicit warning about unsaved work. Each action keeps
the reviewed target and verifies its owner, PID, launch time and executable before proceeding.
The popup lists eligible ordinary applications belonging to the current user; FastMac and
core desktop services are excluded. **All processes** opens the broader Performance view.

Closing an unused app can reduce active memory demand. The popup shows actual macOS memory
pressure separately from occupied RAM; macOS manages cached memory itself. App RSS is an
approximation and may include shared pages. The row's detail explains whether it includes
helpers or only the main app. A displayed size does not guarantee that many bytes will be
freed. Missing or stale CPU readings remain unavailable rather than appearing as zero.

**Check app responses** is explicit and bounded to 32 eligible apps and an eight-second
budget. It uses existing Accessibility access and never opens a permission prompt. Without
access, it explains the requirement; ordinary Quit and Force Quit remain available. The check
requests only an application role, with short timeouts, and does not read windows or document
content. Two slow failures produce **Did not respond to check**, which is not a diagnosis of
a frozen app. Unchecked, unavailable and expired results remain distinct. Closing the popup
cancels outstanding response checks. No apps are automatically quit.

Closing the dashboard keeps monitoring alive and stops folder and AI storage scans. Hiding or
minimizing pauses detailed dashboard sampling. **Quit FastMac** stops the app. Settings is
available in the menu and with ⌘, while a FastMac window is active. Launch at login is opt-in.

One shared activity collector reads system and accessible process counters every 15 seconds.
Health also responds to macOS pressure events. Monitoring does not scan folders, hash files
or inspect project contents. Pause stops recurring health/activity sampling and keeps the
last reading; a manual refresh does not resume monitoring. Disk and AI scans remain manual.

Whole-machine CPU uses **100% for all cores together**. App CPU uses **100% for one fully
occupied core** and can exceed 100%. Initial, missing or discontinuous CPU/rate readings are
unavailable while a baseline is established. Memory occupancy estimates are separate from
macOS memory pressure. Process RSS can count shared pages several times; sums are estimates.
Quit/force-quit actions require confirmation and recheck process identity before signalling.

## Dashboard and navigation

Mac Health now puts its current status and one relevant next action first. Elevated macOS
memory pressure offers **Review memory**; storage or thermal conditions direct the user to
the corresponding review. Larger memory, storage and thermal cards open their details, while
short review cards lead to AI storage, startup items and other useful inspections. Paused
monitoring shows a **Last reading** badge. Text and understated blue/cyan accents adapt to
light and dark appearance.

The sidebar prioritizes Mac Health, Activity History, Memory, Performance, Resources and
Projects. Secondary disk maps and scan history are under **More storage views**, and startup,
advanced, maintenance and administrator tools are under **More tools**. These sections start
collapsed, remember their state and reveal a selected destination when reached from another
part of the app. Folder scans are still requested only by the features that need them.

## Activity History and saved scans

Activity History retains local minute samples for 1, 7 or 30 days, capped at 100 MB. Each
sample includes measured counters and the leading 12 readable app groups. Monitoring pauses,
sleep and collection sessions create gaps. Up to 100 saved moments retain a reading and note.

Select a chart sample to inspect it, save a moment for later, or export the displayed range
as CSV or JSON. Large ranges can be downsampled to 1,500 points; exports contain those
displayed points. Missing values stay empty in CSV and `null` in JSON. App names are
excluded unless selected; internal app identifiers and executable paths are always omitted.
JSON includes units, measurement conventions and coverage information.

Recordings and bookmarks live in `~/Library/Application Support/FastMac/Activity/`. Local app
grouping identifiers can include application paths. Command arguments, environment variables,
project folders and file inventories are not recorded in activity history. Turn recording
off in Settings; existing records remain readable. **Clear history** removes activity records
and bookmarks, with confirmation. Recording can subsequently continue while enabled.

Native disk scans separately save up to 200 local summaries in `~/.fastmac/history/`, with
up to 40 child folders each. These contain scanned paths and sizes. Cancelled scans keep the
previous map and are not saved. Unreadable items produce a marked partial summary; truncated
or partial child lists are not treated as complete evidence of appearing/vanishing folders.
**Scan Again** performs a new scan; a summary cannot restore the full disk map.

## Optional notifications

Notifications default off. Enable them in Settings to request macOS permission while
monitoring is enabled. They cover valid free storage below 10 GB, including zero free bytes;
elevated macOS memory pressure sustained for five minutes; app CPU above 80% of one core for
two continuous minutes; and resident-memory growth of at least 500 MiB across 30 minutes of
continuous readings. Missing samples, long gaps and collection sessions break continuity.

Resident-memory growth is a review cue; caches and active work can cause it, and it does not
diagnose a memory leak. Alerts never quit apps, change startup items or remove files. Accepted
notification scheduling commits independent local cooldowns of six hours; permission denial
or a scheduling failure leaves the transition available. Focus and macOS notification
settings can affect whether an accepted notification is shown.
Settings also offers a one-hour snooze and Resume alerts. Snooze persists across restarts;
sustained-condition observations restart after it expires, while monitoring continues.

## Resources, Projects and Advanced

**Resources** shows physical-interface network throughput, battery charge/cycles and a raw
full-charge/design-capacity estimate. That estimate can differ from Maximum Capacity in
macOS Settings. Network scope is shown: virtual/VPN/loopback/peer links are excluded to reduce
double counting, while physical VPN transport includes overhead. Traffic is not attributed
to apps. GPU utilization uses available IOAccelerator counters experimentally; unsupported
hardware stays unavailable. Thermal state is not a temperature in degrees. Battery
and other temperatures require validated counters and remain unavailable.

**Projects** runs a manual bounded check for TCP listeners in recognized development runtimes.
It groups by working-directory evidence and shows ports, readable RSS and verified process
age. It does not scan project files or read arguments/environment variables. Custom executable
names, non-listening servers and inaccessible processes can be omitted. **Stop…** confirms
one server process and verifies its identity; a listening port is not a recommendation to stop it.

**Advanced** uses manual refresh. Docker inspection reads the saved context and accepts only
a local Unix socket, then lists containers and bounded read-only stats. It does not stop,
execute in, delete or prune containers; remote contexts are unsupported. Sleep assertions show
PIDs, process names and categories while omitting potentially private assertion descriptions.
Browser resource rows are generic executable categories and readable RSS, not identified tabs
or websites. Advanced snapshots are not saved in activity history.

## AI Storage

AI Storage starts idle. Press **Scan** to inspect fixed known locations:

| Tool | Locations |
|---|---|
| Ollama | `~/.ollama/models` |
| Hugging Face | `~/.cache/huggingface/hub` |
| LM Studio | `~/.lmstudio/models`, `~/.cache/lm-studio/models` |
| MLX | `~/.cache/mlx` |

Specific ChatGPT, Codex, Claude and Cursor desktop caches are also reviewed: `fsCachedData`
below known `~/Library/Caches` identifiers, and `Cache`, `Code Cache` and `GPUCache` below
supported application folders. Transcript metadata is measured separately as protected history.
Conversation databases, VM data, browser profiles and whole application support folders are
excluded from cleanup suggestions. Custom model locations are not searched. Scans report logical/allocated sizes and inaccessible or partial results, are
bounded to 30 seconds and 150,000 entries, and can be cancelled.

Review complete supported repository/cache folders individually before staging them. Models
can be valuable or expensive to download again. Ollama is measured and can be revealed in
Finder; remove models through Ollama because manifests can share blobs.

## Review, cleanup and permissions

Folder scans feed the disk maps, Quick Wins and opt-in content duplicate detection.
Applications reviews bundles and associated Library data when opened. Broader ownership
attribution for arbitrary storage is not implemented.

Select items, review the persistent cleanup queue, then confirm **Move to Trash**. Paths and
identities are checked again before moving; replaced paths must be staged again. Protected
system paths, home roots, existing Trash, out-of-scope paths and multiply hard-linked files
are refused. Permanent deletion is unavailable. Moves use `FileManager.trashItem` and are
recorded in the bounded local `~/.fastmac/cleanup.log`.

**Moving to Trash does not free volume space until you empty it in Finder.** Storage cleanup
does not directly reduce CPU or active memory use.

Optional Full Disk Access can be granted to the bundled FastMac.app in System Settings →
Privacy & Security. Without it, protected folders can be hidden and sizes under-reported.
The Settings check is best-effort and does not guarantee access to every folder.

## Remaining scope

Per-app network attribution, validated temperatures/fan controls, audio and Bluetooth tools,
Docker stop actions, custom AI model locations and broader storage
ownership are not shipped. Browser tab attribution is also absent. These are remaining
implementation/compatibility tasks, not paid features.

## Checks and verification

The executable supports diagnostics:

```bash
./.build/release/FastMac --checkall
./.build/release/FastMac --activity-check
./.build/release/FastMac --activity-alert-check
./.build/release/FastMac --activity-monitor-check
./.build/release/FastMac --activity-export-check
./.build/release/FastMac --menu-check /tmp/fastmac-menu-preview
./.build/release/FastMac --quick-actions-check
./.build/release/FastMac --quick-actions-render-check /tmp/fastmac-quick-actions-preview
./.build/release/FastMac --health-render-check /tmp/fastmac-health-preview
./.build/release/FastMac --app-smoke
```

Additional flags are in `Sources/FastMac/main.swift`; the `--e2e` fixture deliberately moves
its generated test data to Trash. The earlier 1.2 packaged release passed **516 feature checks** and
**32 isolated monitoring lifecycle checks**. The native menu/window smoke passed all
**15 checks**, including opening Activity History, Resources, Projects and Advanced Tools.
Version 1.3 verification is recorded below.

Semantic menu foreground contrast and the production header were verified in light/dark
appearances. SwiftUI content renders are useful layout evidence, but ImageRenderer does not
draw every native button/picker. They do not establish complete visual or interactive control
validation.


### Version 1.3 verification

The integrated feature suite passes 563 checks, including 47 quick-action policy fixtures.
Native lifecycle checks pass all 17 cases; menu contrast passes 7 checks and popup/dashboard
fixture rendering passes 32 checks. Native dark popup and dashboard appearance were also
inspected. Confirmation tests were cancelled; no user apps were terminated.

Open Quick Actions by clicking the status item or using FastMac → Open Quick Actions
(⇧⌘0). The small stop icon next to an app opens its Force Quit review.

```sh
build/FastMac.app/Contents/MacOS/FastMac --quick-actions-check
build/FastMac.app/Contents/MacOS/FastMac --quick-actions-render-check .verification/quick-actions
```

### Version 1.3.1 verification

The packaged build 5 reports **595 checks passed** in the integrated suite, **356/356 native
navigation assertions**, **32 monitoring lifecycle checks**, **17 menu/window smoke checks**
and **7 menu contrast checks**. The popup render suite reports **ALL PASS (32 checks)**;
its total includes an informational note about native controls. Scanner fixtures passed
33 assertions against the latest compiled scanner before packaging.

The navigation fixtures host the production views at compact and normal sizes in light and
dark appearances. They cover populated, loading and empty content, long Startup orphan
lists, repeated route changes, and actual native table geometry. Live inspection also
confirmed Startup Items, Administrator and navigation back to Mac Health in the packaged
app. Settings opens with Full Disk Access unchecked until **Check Access** is selected.

Quick Actions now uses a nonactivating panel. Desktop focus/dismissal checks passed and one
controlled regular-app full-screen experiment passed. The complete final-binary full-screen
matrix, including menu-bar-only mode, remains unverified because the desktop changed focus
during the test. Do not interpret the ordinary smoke tests as full-screen acceptance.



### Version 1.4.0: explanations and reviewed actions

The main app now includes these additions. The menu-bar popup's attention feed is a later
integration; its existing quick actions remain in place.

- **Insights:** ranked memory pressure, storage and thermal findings, sustained whole-Mac
  CPU demand, and matched app-memory changes. Each finding includes evidence, its limits,
  a timestamp and a review destination. Health readings older than 90 seconds are not used
  as current evidence. Activity comparisons stop at a session boundary or a gap over 95
  seconds. High CPU is not called a frozen app; memory growth is not called a leak.
- **Consistent memory severity:** Memory and Health use the same macOS pressure reading.
  Occupancy and swap remain explanatory metrics. Per-process CPU no longer turns red solely
  because it exceeds 25% of one core.
- **Process explanations:** click a process name in Performance to inspect its executable,
  owner association, usual role and quitting consequences. Unknown paths remain unknown;
  a familiar name by itself does not identify a system service.
- **Search & Commands:** use the sidebar button or Command-K in FastMac. Option-Command-K
  registers a global shortcut where available; conflicts are disclosed in the palette.
  Search pages and eligible running apps, or explicitly include discovered TCP servers and
  ports. Quit and stop entries open a confirmation and reuse process identity checks.
- **Loaded AI models:** AI Storage has separate disk and runtime tabs. The runtime tab
  explicitly queries Ollama at 127.0.0.1:11434 and LM Studio's v1 API at 127.0.0.1:1234.
  It lists loaded instances and reports metrics only when provided by the runtime. LM
  Studio's file size is never labelled as active RAM. An optional LM Studio API token
  stays in memory for the view session. Unload rechecks the reviewed identity, sends a
  runtime-specific request and checks the result; it never deletes model files.
- **Agent sessions:** Projects has Servers & ports and Agent sessions tabs. Observation is
  opt-in, samples every five seconds while the dashboard remains open, and stops when
  the dashboard closes. Native claude, codex, opencode and cursor-agent executables are
  recognized; script wrappers may be missed. Only observed ancestry is retained. Missing
  readable data does not establish exit. Surviving descendants can be reviewed and stopped
  individually with SIGTERM; there is no automatic force-kill. No prompts, transcripts,
  command arguments or environment variables are read. Observations stay in memory, capped
  at 64 sessions and 512 descendants per session, until cleared or the dashboard closes.
- **Startup changes:** the first readable Startup scan establishes a local baseline.
  Later scans flag new or changed configurations inside Startup Items. Acknowledging an
  expected item accepts only that configuration. Missing/unreadable entries do not claim
  removal. This is a scan-based in-app review, not continuous login-item watching or OS
  notifications. Signature verification and automatic disabling are not part of this flow.

Activity sampling retains up to 240 recent snapshots in memory even when disk recording is
turned off, so short-window diagnosis does not require enabling saved history. Closing the
app discards these snapshots. Existing saved-history retention and privacy settings apply
separately. Diagnosis uses measured observations and local rules; no paid AI API is needed.

Runtime HTTP requests are ephemeral, have request/resource deadlines, reject redirects, and
cap returned data at 1 MiB. Only the listed loopback runtime endpoints are permitted. No LAN
or cloud runtime is contacted. Custom ports, llama.cpp/MLX API adapters, throughput estimates
and model-fit predictions are not implemented in this version.

Protocol references: [Ollama running models](https://docs.ollama.com/api/ps),
[Ollama keep-alive/unload](https://docs.ollama.com/api/generate),
[LM Studio v1 model list](https://lmstudio.ai/docs/developer/rest/list),
[LM Studio instance unload](https://lmstudio.ai/docs/developer/rest/unload).

Additional diagnostic commands:

```sh
build/FastMac.app/Contents/MacOS/FastMac --insights-check
build/FastMac.app/Contents/MacOS/FastMac --insights-async-check
build/FastMac.app/Contents/MacOS/FastMac --navigation-check
build/FastMac.app/Contents/MacOS/FastMac --agent-observation-check
```

The async checks use an injected runtime transport; they never unload real models. The
agent-observation diagnostic performs one read-only process snapshot without starting a
watcher or signalling processes. Startup persistence checks use temporary fixtures.

Packaged version 1.4.0 (build 6) verification on 2026-10-04 passed 646 feature checks,
5 injected model-action checks, 428 native navigation assertions and 32 activity-monitor
checks. A read-only process snapshot observed 346 readable processes in approximately
22 ms without reaching the probe limit; this is one measurement, not a performance guarantee.
Logs are in `.verification/insights-release-*.log`.

Live inspection confirmed that Insights renders with its evidence and sidebar, and that
Command-K opens the palette with the search field focused. Further interactive checks
stopped when the shared desktop changed during testing. Global shortcut invocation,
palette keyboard filtering/navigation and real runtime unloads have not been verified
interactively. Runtime actions were tested with injected responses, without unloading a
user's models or stopping user processes. The earlier full-screen popup acceptance gap
also remains open. Screenshot and executable identity are recorded under
`.verification/insights-native/`.
