# LCL Socket Inspector: Design Document

**Status:** Proposed
**Compile flag:** `{$IFDEF ENABLE_LCL_SOCKET_DIAG}`

## Problem

The LCL has no automated testing story for UI interactions like docking,
drag-and-drop form design, and property editing. External tools based on
AT-SPI/ATK (dogtail, LDTP, KDE's selenium-webdriver-at-spi) can't see
most LCL controls because the LCL's accessibility implementation is
incomplete — custom-drawn controls like SynEdit, the form designer, and
the Object Inspector's custom editors appear as opaque "drawing area"
widgets to the accessibility stack.

Building full ATK support is a large project. In the meantime, we need
a way to inspect and drive the LCL's own object tree from external tools.

## Solution

A TCP socket service compiled into the LCL itself, gated behind
`{$IFDEF ENABLE_LCL_SOCKET_DIAG}`. When enabled, the LCL starts a
localhost-only JSON-over-TCP server that exposes the live control tree,
property values, and internal diagnostic state. External scripts (Python,
bash, anything that speaks TCP) can connect and query or command the
running application.

## Architecture

```
  Python test script          LCL Application (Eleazar IDE)
  ┌──────────────┐           ┌─────────────────────────────────┐
  │              │  JSON/TCP  │  TLCLDiagServer (background     │
  │  connect()   │──────────→│  thread, localhost:4747)         │
  │  send cmd    │           │    │                             │
  │  recv json   │←──────────│    ├─ tree: walk Screen.Forms[], │
  │              │           │    │   TWinControl.Controls[]    │
  └──────────────┘           │    ├─ props: RTTI + LCL-specific │
  (or: xdotool,             │    ├─ state: lock counts, flags  │
   dogtail, curl,            │    └─ actions: click, type, focus│
   netcat, etc.)             │                                  │
                             │  Main thread (via QueueAsyncCall)│
                             │    └─ executes mutation commands │
                             └─────────────────────────────────┘
```

### Thread Safety

The server thread receives commands and reads the control tree. For
read-only queries (tree, props, state), it can walk the tree directly
since the main thread is either idle or processing events — the GIL-like
nature of the LCL event loop means the control tree is stable between
event dispatches.

For mutation commands (click, type, focus, resize), the server thread
must NOT touch the control tree directly. Instead, it posts the command
via `Application.QueueAsyncCall`, which schedules it to run on the main
thread during the next idle cycle. The server thread blocks on an
RTLEvent until the main thread signals completion and provides the
result.

### Where It Lives

```
lcl/
  lcldiagserver.pas          ← the unit (server, protocol, tree walker)
lcl/forms.pp
  TApplication               ← starts/stops the server
lcl/include/application.inc
  TApplication.Run           ← server startup hook
```

The entire unit is wrapped in `{$IFDEF ENABLE_LCL_SOCKET_DIAG}`. When
the define is absent, zero code is compiled and there is no runtime cost.

### Startup

In `TApplication.Run`, before entering the event loop:

```pascal
{$IFDEF ENABLE_LCL_SOCKET_DIAG}
FDiagServer := TLCLDiagServer.Create(Self);
FDiagServer.Start;  // starts background thread, binds to localhost:4747
DebugLn('[LCLDiag] Inspector listening on localhost:', IntToStr(FDiagServer.Port));
{$ENDIF}
```

The IDE's `lazarus.lpi` (or `build.sh`) passes `-dENABLE_LCL_SOCKET_DIAG`
to enable it. The port defaults to 4747 but can be overridden via
environment variable `LCL_DIAG_PORT`.

## Protocol

JSON over TCP, newline-delimited. One JSON object per line in each
direction. Request/response pairs identified by an `id` field.

### Query: Control Tree

```json
→ {"id":1, "cmd":"tree"}
← {"id":1, "result": {
     "class":"TApplication",
     "forms": [
       {
         "class":"TMainIDEBar", "name":"MainIDEBar",
         "bounds":{"l":0,"t":0,"w":1920,"h":85},
         "visible":true, "showing":true,
         "autoSizeLock":0,
         "children": [
           {
             "class":"TCoolBar", "name":"CoolBar1",
             "bounds":{"l":0,"t":0,"w":1920,"h":52},
             "visible":true,
             "autoSizeLock":0,
             "children": [...]
           }
         ]
       },
       {
         "class":"TObjectInspectorDlg", "name":"ObjectInspectorDlg1",
         ...
       }
     ]
   }}
```

### Query: Properties of a Control

```json
→ {"id":2, "cmd":"props", "path":"MainIDEBar/CoolBar1"}
← {"id":2, "result": {
     "class":"TCoolBar",
     "name":"CoolBar1",
     "bounds":{"l":0,"t":0,"w":1920,"h":52},
     "clientRect":{"l":0,"t":0,"w":1920,"h":52},
     "visible":true, "enabled":true, "showing":true,
     "handleAllocated":true,
     "autoSizeLock":0,
     "winControlFlags":["wcfRealizingBounds"],
     "anchors":["akLeft","akTop","akRight"],
     "align":"alTop",
     "constraints":{"minW":0,"minH":0,"maxW":0,"maxH":0},
     "parentClass":"TMainIDEBar",
     "controlCount":3
   }}
```

### Query: Diagnostic State (for debugging auto-sizing)

```json
→ {"id":3, "cmd":"diag", "path":"MainIDEBar"}
← {"id":3, "result": {
     "autoSizeLock":0,
     "autoSizeLockReasons":[],
     "formUpdateCount":0,
     "wmSizeCounter":4523,
     "isAutoSizing":false,
     "autoSizePhases":["caspNone"],
     "parentChainLocks": [
       {"name":"MainIDEBar","lock":0},
       {"name":"(no parent)","lock":0}
     ]
   }}
```

### Query: Find Controls

```json
→ {"id":4, "cmd":"find", "class":"TEdit"}
← {"id":4, "result": [
     {"path":"ObjectInspectorDlg1/ValueEdit", "class":"TEdit", "text":"Button1"},
     {"path":"SearchForm/SearchEdit", "class":"TEdit", "text":""}
   ]}

→ {"id":5, "cmd":"find", "name":"CompFilterEdit"}
← {"id":5, "result": [
     {"path":"ObjectInspectorDlg1/CompFilterEdit",
      "class":"TCustomControlFilterEdit", "text":""}
   ]}
```

### Action: Click

```json
→ {"id":6, "cmd":"click", "path":"MainIDEBar/CoolBar1/RunButton"}
← {"id":6, "result":"ok"}
```

Executed on the main thread via `QueueAsyncCall`. Synthesizes
`LM_LBUTTONDOWN` + `LM_LBUTTONUP` messages to the target control.

### Action: Type Text

```json
→ {"id":7, "cmd":"type", "path":"ObjectInspectorDlg1/ValueEdit", "text":"Hello"}
← {"id":7, "result":"ok"}
```

### Action: Focus

```json
→ {"id":8, "cmd":"focus", "path":"ObjectInspectorDlg1/ValueEdit"}
← {"id":8, "result":"ok"}
```

### Action: Resize (for testing resize loops)

```json
→ {"id":9, "cmd":"resize", "path":"MainIDEBar", "w":1920, "h":120}
← {"id":9, "result":"ok"}
```

### Action: Dock (simulates drag-to-dock)

```json
→ {"id":10, "cmd":"dock", "source":"ObjectInspectorDlg1",
   "target":"MainIDEBar", "side":"left"}
← {"id":10, "result":"ok"}
```

This is higher-level than raw mouse simulation — it calls the LCL's
docking API directly, which is more reliable and testable than
coordinate-based xdotool dragging.

### Meta: Ping / Version

```json
→ {"id":0, "cmd":"ping"}
← {"id":0, "result":{"version":"1.0","app":"Eleazar","pid":12345}}
```

## Event Ring Buffer

### The Problem with DebugLn

The current LCL diagnostic approach is `DebugLn` — unstructured text
written to stderr, redirected to a file. This has fundamental problems:

1. **2.7GB log files.** A single desktop-switch event can generate
   hundreds of thousands of `WMSize` calls. Each one writes to the log.
   The log becomes enormous and useless.

2. **No timestamps.** When did the resize storm start? When did it end?
   How long did the IDE spend stuck in a loop? You can't tell from the
   log because `DebugLn` doesn't timestamp anything.

3. **No structure.** Grepping for `WMSize` in a 2.7GB log gives you
   millions of lines with no way to correlate them — which control,
   what size, what lock count, what triggered it.

4. **Write amplification kills performance.** Every `DebugLn` is a
   `write()` syscall. During a resize storm, the I/O overhead of
   logging makes the storm worse.

5. **Post-mortem only.** You can only read the log after the IDE exits
   (or crashes). You can't query the running IDE to ask "what happened
   in the last 5 seconds?"

### The Solution: `TLCLEventRing`

A fixed-size circular buffer of structured JSON events, held in memory.
No file I/O. No `DebugLn`. Events are written by the LCL internals
(auto-sizing, WMSize, handle allocation, showing, exceptions) and read
by the socket inspector or dumped on crash.

```pascal
TLCLDiagEvent = record
  Timestamp: TDateTime;          // millisecond precision
  SeqNo: QWord;                  // monotonic sequence number
  Category: TLCLDiagCategory;    // evAutoSize, evWMSize, evHandle,
                                 //   evShow, evException, evDock, ...
  ControlName: string;           // DbgSName(Self)
  ControlClass: string;          // Self.ClassName
  Detail: string;                // JSON payload (varies by category)
end;

TLCLEventRing = class
  FBuffer: array of TLCLDiagEvent;
  FCapacity: Integer;            // default 64K entries
  FHead: Integer;                // next write position
  FSeqNo: QWord;                 // monotonic counter
  FLock: TCriticalSection;       // thread-safe writes
  procedure Push(Cat: TLCLDiagCategory;
    const AControlName, AControlClass, ADetail: string);
  function Query(Since: TDateTime; Cat: TLCLDiagCategory;
    MaxResults: Integer): TJSONArray;
  function QueryBySeq(SinceSeq: QWord; MaxResults: Integer): TJSONArray;
  function Dump: TJSONArray;     // full buffer, oldest first
  function Stats: TJSONObject;   // category counts, rate/sec
end;
```

### What Gets Logged

Every `DebugLn` we added to the LCL gets replaced with a ring buffer
push. The categories:

| Category | Replaces | Detail payload |
|----------|----------|----------------|
| `evWMSize` | `WMSizeCounter mod 500` hack | `{"w":1920,"h":85,"lock":0,"flags":["wcfRealizingBounds"]}` |
| `evAutoSizeDisable` | `DisableAutoSizing` DebugLn | `{"reason":"TMainIDEBar.DoSetMainIDEHeight","count":1,"parent":""}` |
| `evAutoSizeEnable` | `EnableAutoSizing` DebugLn | `{"reason":"...","count":0,"action":"DoAllAutoSize"}` |
| `evAutoSizeLoop` | Loop iteration counter | `{"iteration":45,"control":"MainIDEBar","height":32005}` |
| `evHandleCreate` | None (currently silent) | `{"control":"CoolBar1","class":"TCoolBar"}` |
| `evShow` | None | `{"control":"MainIDEBar","visible":true,"showing":true}` |
| `evException` | `HandleException` logging | `{"class":"ELayoutException","msg":"WM_SIZE LOOP","stack":"..."}` |
| `evDock` | None | `{"source":"ObjectInspector","target":"MainIDEBar","side":"left"}` |
| `evBoundsRealize` | None | `{"control":"CoolBar1","l":0,"t":0,"w":1920,"h":52}` |
| `evConstraintSend` | Proposed WM logging | `{"control":"MainIDEBar","minH":85,"maxH":85}` |

### Ring Buffer Sizing

At 64K entries with ~200 bytes average per entry, the buffer uses ~12MB
of RAM. A resize storm generating 10,000 WMSize events per second fills
the buffer in ~6 seconds, discarding the oldest events. This is exactly
right — you get the last 6 seconds of history at storm rates, or minutes
of history at normal rates.

The capacity is configurable via environment variable
`LCL_DIAG_RING_SIZE` (default 65536).

### Socket Protocol: Event Queries

```json
→ {"id":11, "cmd":"events", "since_ms":5000}
← {"id":11, "result": {
     "count": 847,
     "events": [
       {"seq":44201, "ts":"2026-03-28T14:22:01.003",
        "cat":"evWMSize", "ctrl":"MainIDEBar:TMainIDEBar",
        "detail":{"w":1920,"h":85,"lock":0}},
       {"seq":44202, "ts":"2026-03-28T14:22:01.003",
        "cat":"evAutoSizeDisable", "ctrl":"MainIDEBar:TMainIDEBar",
        "detail":{"reason":"DoSetMainIDEHeight","count":1}},
       ...
     ]
   }}
```

Query by sequence number (for polling without gaps):

```json
→ {"id":12, "cmd":"events", "since_seq":44200, "max":100}
← {"id":12, "result": {"count":100, "events":[...]}}
```

Category filter:

```json
→ {"id":13, "cmd":"events", "since_ms":10000, "cat":"evWMSize"}
← {"id":13, "result": {"count":4523, "events":[...]}}
```

Rate statistics (for detecting storms without pulling all events):

```json
→ {"id":14, "cmd":"event_stats"}
← {"id":14, "result": {
     "total":198453,
     "buffer_used":65536,
     "oldest_seq":132917,
     "newest_seq":198453,
     "rates_per_sec": {
       "evWMSize": 2.3,
       "evAutoSizeDisable": 1.1,
       "evAutoSizeEnable": 1.1,
       "evException": 0.0
     },
     "peak_rates_per_sec": {
       "evWMSize": 12847.0,
       "evAutoSizeDisable": 6423.0
     }
   }}
```

### Crash Dump

On unhandled exception or SIGSEGV (via `SignalHandler`), the ring buffer
dumps its contents to `/tmp/lcl-diag-crash-<pid>.json`. This replaces
the 2.7GB log file with a ~12MB structured JSON file containing the last
few seconds of LCL activity before the crash — exactly the window you
need for diagnosis.

### How It Hooks Into DebugLn (Not Replaces It)

**Key design decision:** We do NOT replace `DebugLn` calls with ring
buffer pushes. We hook the existing `TLazLoggerFile` callback
infrastructure so that every `DebugLn` in the entire LCL automatically
feeds the ring buffer AND still writes to disk as before.

`TLazLoggerFile.DoDebugLn` (in `lazlogger.pas`) already has two
callback hooks that fire before the file write:

```pascal
// lazlogger.pas line 781-824 (existing upstream code):
procedure TLazLoggerFile.DoDebugLn(s: string; AGroup: PLazLoggerLogGroup);
begin
  // 1. Extended callback (fires first)
  CB2 := OnDebugLnEx;
  if CB2 <> nil then begin
    Handled := False;
    CB2(Self, s, Indent, Handled, CbInfo);
    if Handled then Exit;         // ← can suppress file write
  end;

  // 2. Simple callback (fires second)
  CB := OnDebugLn;
  if CB <> nil then begin
    Handled := False;
    CB(Self, s, Handled);
    if Handled then Exit;         // ← can suppress file write
  end;

  // 3. File write (always, unless a callback set Handled)
  FileHandle.WriteLnToFile(s);
end;
```

Neither callback is currently used by the LCL. We hook `OnDebugLnEx`:

```pascal
procedure LCLDiagDebugLnHandler(Sender: TObject;
  var LogTxt, LogIndent: string; var Handled: Boolean;
  const AnInfo: TLazLoggerWriteExEventInfo);
begin
  // Push to ring buffer — no I/O, just memory copy
  LCLDiagRing.Push(LogTxt);
  Handled := False;  // DON'T suppress — let the file write proceed
end;

// During initialization:
(DebugLogger as TLazLoggerFile).OnDebugLnEx := @LCLDiagDebugLnHandler;
```

This gives us **both outputs simultaneously**:

```
DebugLn('something')
  → OnDebugLnEx → ring buffer push (memory, ~100ns)
  → Handled=False, so continues...
  → FileHandle.WriteLnToFile → disk write (as always)
```

**Consequences for our code:**

1. **All existing upstream `DebugLn` calls** — automatically captured
   in the ring. No changes needed. Every `VerboseSizeMsg`, every
   `VerboseAllAutoSize`, every `DEBUGGTK2FRAMESIZE` writeln — they all
   flow through `DoDebugLn` and hit our hook.

2. **Our `WriteLn(StdErr, ...)` calls** — these bypass the logger
   entirely. Convert them to `DebugLn` so they flow through the
   pipeline. This is a cleanup we owe anyway.

3. **The `WMSizeCounter mod 500` hack** — remove it. Every WMSize
   `DebugLn` hits the ring buffer naturally. The ring handles
   throttling by overwriting old entries. The `event_stats` query
   gives rate-per-second without pulling all events.

4. **Our custom `{$IFDEF DEBUG_LCL}` and `{$IFDEF DEBUG_WM_SIZE}`** —
   remove them. The existing upstream defines (`VerboseSizeMsg`,
   `VerboseAllAutoSize`, etc.) already gate the `DebugLn` calls. With
   the ring buffer, even unconditional `DebugLn` is cheap enough to
   leave on in debug builds.

5. **Production builds** — with `ENABLE_LCL_SOCKET_DIAG` off, the
   hook is never installed. `OnDebugLnEx` is nil. The `if CB2 <> nil`
   check is a single pointer comparison — effectively zero cost.

### Per-Control Gating: `TLCLComponent.DebugLogging`

The ring buffer captures everything `DebugLn` emits. But most LCL
`DebugLn` calls fire for every control — every button, every panel,
every splitter. When debugging a resize loop on `MainIDEBar`, you
don't want noise from 200 other controls.

`TLCLComponent` (the base class for all LCL components, in
`lclclasses.pp`) now has:

```pascal
TLCLComponent = class(TComponent)
private
  FDebugLogging: Boolean;
public
  property DebugLogging: Boolean read FDebugLogging write FDebugLogging;
end;
```

Verbose `DebugLn` calls in the LCL guard on this property:

```pascal
// In TWinControl.WMSize:
if DebugLogging then
  DebugLn(['[WMSize] ', DbgSName(Self), ' w=', Message.Width,
    ' h=', Message.Height, ' lock=', FAutoSizingLockCount]);

// In TControl.DisableAutoSizing:
if DebugLogging then
  DebugLn(['[DisableAutoSizing] ', DbgSName(Self),
    ' count=', FAutoSizingLockCount, ' reason="', AReason, '"']);
```

Default is `False` — silent. You turn it on for the controls you care
about:

```pascal
MainIDEBar.DebugLogging := True;
ObjectInspectorDlg1.DebugLogging := True;
```

Or from the socket inspector:

```json
→ {"id":15, "cmd":"set_debug", "path":"MainIDEBar", "value":true}
← {"id":15, "result":"ok"}
```

Or enable for an entire class at once:

```json
→ {"id":16, "cmd":"set_debug_class", "class":"TAnchorDockPage", "value":true}
← {"id":16, "result":{"count":12}}
```

Or enable debug on **all forms and all dock sites** in one shot with `debug_all`
(implemented in `lcldiagserver.pas`). This walks `Screen.CustomForms[]` directly
so it works even when dock site controls are buried behind unnamed
`TAnchorDockPageControl`/`TAnchorDockPage` nodes that path-based commands can't
traverse:

```json
→ {"id":17, "cmd":"debug_all"}
← {"id":17, "result":{"forms_set":7,"docksites_set":16,"value":true}}

→ {"id":18, "cmd":"debug_all", "value":false}
← {"id":18, "result":{"forms_set":7,"docksites_set":16,"value":false}}
```

`value` defaults to `true` if omitted.

**Three layers, each independent:**

| Layer | Controls | Purpose |
|-------|----------|---------|
| `DebugLogging` on component | Which controls emit | Per-control noise filter |
| `OnDebugLnEx` hook | What happens to emitted text | Routes to ring buffer |
| Socket inspector queries | How you read the ring | Remote/programmatic access |

### Global Singleton

```pascal
var
  LCLDiagRing: TLCLEventRing;  // created in lcldiagserver initialization
```

Accessible from any LCL unit that uses `lcldiagserver`. The ring is
created during unit initialization (before `TApplication.Create`) and
destroyed during finalization (after everything else).

The `OnDebugLnEx` hook is installed immediately after the ring is
created, so even early startup `DebugLn` calls are captured.

## Implementation Plan

### Phase 1: Ring Buffer + Read-Only Inspector

The minimum viable feature. The ring buffer and read-only queries.

1. **`lcldiagserver.pas`** — new unit, everything in one file:
   - `TLCLEventRing` — circular buffer, thread-safe push/query
   - `TLCLDiagServer` — owns the `TInetServer`, spawns connection threads
   - `TLCLDiagConnection` — per-client thread, reads commands, writes JSON
   - `WalkControlTree(ARoot: TControl): TJSONObject` — recursive tree builder
   - `GetControlProps(AControl: TControl): TJSONObject` — property dumper
   - `FindControl(ARoot, APath): TControl` — path-based lookup
   - `LCLDiagRing: TLCLEventRing` global singleton
   - Pattern: follow `TFpDebugTcpServer` in `components/fpdebug/`

2. **Hook `OnDebugLnEx`** — one line installs the ring buffer:
   - All existing `DebugLn` calls (upstream and ours) are captured automatically
   - No per-callsite changes needed for the ring buffer to work

3. **Clean up our additions** — convert to standard `DebugLn`:
   - `WriteLn(StdErr, ...)` in `wincontrol.inc`, `customform.inc` → `DebugLn`
   - Remove `{$IFDEF DEBUG_WM_SIZE}` / `WMSizeCounter mod 500` hack
   - Remove `{$IFDEF DEBUG_LCL}` — use upstream defines or make unconditional
   - Keep the `HandleException` logging in `application.inc` as `DebugLn`
   - Add `SignalHandler` hook to dump ring to crash file

4. **`forms.pp` + `application.inc`** — startup/shutdown hooks:
   ```pascal
   {$IFDEF ENABLE_LCL_SOCKET_DIAG}
   uses lcldiagserver;
   {$ENDIF}
   ```
   - `TApplication.Run` — create and start server before event loop
   - `TApplication.Destroy` — stop server and free
   - Unit `initialization` — create `LCLDiagRing` + install `OnDebugLnEx` hook
   - Unit `finalization` — unhook, destroy ring

5. **`build.sh`** — add `-dENABLE_LCL_SOCKET_DIAG` to make options

6. **`test_inspector.py`** — Python test client:
   - Connect to localhost:4747
   - Request tree, verify MainIDEBar exists
   - Request props, verify bounds are sane (not 32000px)
   - Request events, verify no `evException` entries
   - Request event_stats, verify WMSize rate < threshold
   - Request diag, verify autoSizeLock == 0

### Phase 2: Mutations via QueueAsyncCall

5. Action commands: click, type, focus, resize
6. Each action is wrapped in a `QueueAsyncCall` thunk
7. Server thread blocks on `RTLEvent` until main thread completes
8. Result (ok or error) sent back to client

### Phase 3: Test Harness

9. **`tests/uitest_smoke.py`** — smoke test suite:
   - Fresh install: launch, verify window appears, verify bounds
   - Docking: dock Object Inspector to main bar, verify tree changes
   - Property edit: focus a control, change a property, verify
   - Resize: resize main bar, verify no lock count leaks
   - Desktop switch: trigger layout change, verify WMSize count is bounded

10. **CI integration:** `Xvfb` + headless launch + test suite

### Phase 4: Live Debugging Tool

11. **`tools/lcl-inspector`** — standalone GUI or TUI client:
    - Real-time tree view with auto-refresh
    - Highlight control under cursor (send highlight command)
    - Lock count monitoring with alerts
    - WMSize rate graph

## Reference Implementation

The codebase already has `TFpDebugTcpServer` in
`components/fpdebug/app/fpdserver/debugtcpserver.pas` which uses
exactly this pattern: `ssockets` + `TInetServer` + JSON + background
thread + per-connection threads. We can follow its structure closely.

The `TTestInsightServer` in `components/fpcunit/ide/testinsightserver.pas`
is another reference — it uses `TFPHttpServer` for an HTTP-based
approach. HTTP would make it accessible from browsers and curl, but
adds overhead. The raw TCP approach is simpler and lower-latency for
programmatic test clients.

## Security

- **Localhost only.** The `TInetServer` is bound to `127.0.0.1`.
  No remote connections accepted.
- **Compile-time gated.** `{$IFDEF ENABLE_LCL_SOCKET_DIAG}` means
  production builds have zero attack surface — the code doesn't exist.
- **No authentication.** Localhost binding is sufficient for a
  development/testing tool. If someone has local access to your machine,
  they already have access to the process.

## Advantages Over DebugLn-Only

The ring buffer does NOT replace DebugLn — it hooks into it via
`OnDebugLnEx`. You get **both** simultaneously: disk logs as always,
plus the ring buffer.

| Aspect | DebugLn to file alone | DebugLn + Ring Buffer |
|--------|----------------------|----------------------|
| Output size | 2.7GB in one session | Same on disk, 12MB fixed in memory |
| Structure | Unstructured text | Text on disk + structured in ring |
| Timestamps | None | Millisecond precision in ring |
| Performance hit | `write()` syscall per line | Same + ~100ns memory copy |
| Queryable at runtime | No (post-mortem only) | Yes (socket query) |
| Filterable | `grep` after the fact | Category filter at query time |
| Rate detection | Manual log inspection | Built-in rate stats |
| Crash diagnostics | Hope the file flushed | Auto-dump last N events to JSON |
| Callsite changes needed | N/A | Zero — hooks existing callbacks |

## Advantages Over AT-SPI

| Aspect | AT-SPI/dogtail | LCL Socket Inspector |
|--------|---------------|---------------------|
| Sees custom-drawn controls | No (opaque "drawing area") | Yes (walks LCL tree) |
| Internal state (lock counts, flags) | No | Yes |
| Event history | No | Ring buffer with timestamps |
| Works without accessibility runtime | No (needs at-spi2-core, ATK bridge) | Yes (just TCP) |
| WM-independent | Partially (needs D-Bus session) | Yes |
| Docking API access | No (must simulate mouse) | Yes (calls dock API directly) |
| Setup complexity | Medium (packages, env vars) | Zero (compiled in) |
| Language support | Python only (dogtail) | Any language with TCP sockets |

## Advantages Over xdotool

| Aspect | xdotool | LCL Socket Inspector |
|--------|---------|---------------------|
| Coordinate-dependent | Yes (brittle) | No (path-based) |
| Sees internal state | No | Yes |
| Event history | No | Ring buffer with timestamps |
| Works headless | Partially (needs Xvfb) | Yes (queries work without display) |
| Docking testing | Fragile (pixel coordinates) | Reliable (API calls) |
| Diagnostic data | None | Lock counts, flags, rates, events |

## Combined Strategy

The LCL Socket Inspector doesn't replace xdotool and dogtail — it
complements them:

- **Socket Inspector:** LCL tree queries, diagnostics, API-level actions
- **xdotool:** Raw input for testing actual mouse/keyboard paths
- **dogtail:** Accessibility verification (once ATK is implemented)

A typical test might:
1. Use the socket inspector to verify the IDE started cleanly
2. Use xdotool to simulate a real user docking a window
3. Use the socket inspector to verify the dock state is correct
4. Use the socket inspector to check for lock count leaks
