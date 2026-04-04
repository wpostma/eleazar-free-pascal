# Session notes — LCL diagnostic socket & tooling

## Goal

Add a **localhost TCP diagnostic service** to the LCL (behind `{$IFDEF ENABLE_LCL_SOCKET_DIAG}`) so tools can inspect the live control tree, read a **ring buffer of `DebugLn` lines**, and toggle **per-control `DebugLogging`** without relying on AT-SPI or coordinate hacks. Pair this with a **Python client** and **build integration** for bigide.

## What shipped

### `lcl/lcldiagserver.pas`

- **`TLCLEventRing`**: Thread-safe circular buffer of structured events (seq, timestamp, text). Size defaults to 65536; override with `LCL_DIAG_RING_SIZE`.
- **`DebugLn` hook**: Wraps `TLazLoggerFile.OnDebugLn` via a small `TDiagDebugLnHook` object (`TLazLoggerWriteEvent` is `of object`). Previous handler is chained so **disk logging is unchanged**.
- **`TLCLDiagServer`**: Accepts on `127.0.0.1`, port from `LCL_DIAG_PORT` or **4747**, then tries **4747–4756** if bind fails.
- **Protocol**: One JSON object per line (newline-terminated), one JSON response per line.
- **Commands** (v1): `ping`, `tree` (optional `depth`), `forms` (depth 0), `props` (`path` like `FormName/Child/...`), `events` (`since_seq`, `max`), `stats`, `set_debug` (`path`, `value` true/false), `find` (`name`/`class`/`caption` substring, optional `set_debug` bool), `debug_all` (optional `value` bool, default true).
- **Without the define**: unit compiles to empty `LCLDiagStartServer` / `LCLDiagStopServer` — no socket code linked.

### Hooks

- **`lcl/forms.pp`**: `LCLDiagServer` in implementation `uses`.
- **`lcl/include/application.inc`**: `LCLDiagStartServer` at the start of `TApplication.Run` (after main form setup path; before `WidgetSet.AppRun`).
- Ring install/teardown: unit `initialization` / `finalization`.

### `build.sh`

- **`DIAG=1`**: passes `OPT="-dENABLE_LCL_SOCKET_DIAG"` to `make` so LCL + IDE get the server.
- Example: `DIAG=1 ./build.sh` (default target still `bigide`, second arg still widgetset e.g. `gtk2`).

### `tools/lcl-inspector.py`

- Connects to `LCL_DIAG_HOST` / `LCL_DIAG_PORT` (defaults `localhost` / `4747`).
- **REPL**: `./tools/lcl-inspector.py`
- **Subcommands**: `ping`, `tree`, `forms`, `props`, `events`, `stats`, `watch`, `set-debug PATH on|off`
- **Watch**: polls `events` and prints new lines (useful during resize/layout storms).

### Earlier related pieces (context)

- **`TLCLComponent.DebugLogging`** in `lcl/lclclasses.pp`: noisy LCL diagnostics use `if DebugLogging then DebugLn(...)` instead of unconditional `WriteLn(StdErr, ...)`.
- **`test-lcl.sh`**: build LCL + `runtests`, optional `DIAG=1` for the same define, modes `all` / `build` / `run` / `quick` / `smoke` (smoke still placeholder until IDE automation uses the socket).
- **Design doc**: `LCL_SOCKET_INSPECTOR.md` describes the broader plan (actions, crash dumps, etc.); implementation here is **phase 1** (read-mostly tree + ring + `set_debug`).

## Quick usage

```bash
DIAG=1 ./build.sh
./lazarus   # or your wrapper e.g. ./runit
```

In another terminal:

```bash
./tools/lcl-inspector.py ping
./tools/lcl-inspector.py forms
./tools/lcl-inspector.py tree --depth 5
./tools/lcl-inspector.py watch
```

## Environment variables

| Variable            | Purpose                                      |
|---------------------|----------------------------------------------|
| `LCL_DIAG_PORT`     | Base port (default 4747)                     |
| `LCL_DIAG_RING_SIZE`| Ring buffer capacity (default 65536)         |
| `DIAG=1`            | Enable define when using `build.sh`          |

## Caveats

- Tree and property reads run from **socket worker threads** while the GUI thread may be mutating the tree; code is defensive (`try/except`) but not a formal thread-safe API.
- `set_debug` mutates `TControl.DebugLogging` from the socket thread — acceptable for diagnostics; do not treat as production feature.
- If the actual bound port differs from 4747 (port scan), **`ping`** returns the real `port` in `result`; point the Python client at that port or set `LCL_DIAG_PORT` before starting the app.

## Files touched (this line of work)

- `lcl/lcldiagserver.pas` (new)
- `lcl/forms.pp` (uses `LCLDiagServer`)
- `lcl/include/application.inc` (`LCLDiagStartServer` in `Run`)
- `build.sh` (`DIAG=1` → `OPT`)
- `tools/lcl-inspector.py` (client)
