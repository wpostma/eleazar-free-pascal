#!/usr/bin/env python3
"""
lcl-inspector: Connect to the Eleazar/Lazarus LCL diagnostic socket.

Usage:
  lcl-inspector.py                       Interactive REPL
  lcl-inspector.py ping                  Ping the server
  lcl-inspector.py tree [--depth N]      Dump control tree
  lcl-inspector.py forms                 List top-level forms
  lcl-inspector.py props PATH            Properties of a control
  lcl-inspector.py events [--max N]      Recent events from ring buffer
  lcl-inspector.py stats                 Ring buffer statistics
  lcl-inspector.py watch                 Tail events continuously
  lcl-inspector.py set-debug PATH on|off Toggle DebugLogging on a control

Environment:
  LCL_DIAG_HOST   default: localhost
  LCL_DIAG_PORT   default: 4747
"""

import socket
import json
import sys
import os
import time
import textwrap
from argparse import ArgumentParser

HOST = os.environ.get("LCL_DIAG_HOST", "localhost")
PORT = int(os.environ.get("LCL_DIAG_PORT", "4747"))

BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
RESET = "\033[0m"

_next_id = 0


def next_id():
    global _next_id
    _next_id += 1
    return _next_id


class DiagClient:
    def __init__(self, host, port, timeout=5.0):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect((host, port))
        self.buf = b""

    def send(self, cmd_dict):
        cmd_dict.setdefault("id", next_id())
        line = json.dumps(cmd_dict) + "\n"
        self.sock.sendall(line.encode("utf-8"))
        return self._recv_line()

    def _recv_line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("Server closed connection")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line.decode("utf-8", errors="replace"))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def format_tree(node, indent=0):
    """Pretty-print a control tree node."""
    prefix = "  " * indent
    cls = node.get("class", "?")
    name = node.get("name", "")
    w, h = node.get("width", 0), node.get("height", 0)
    vis = node.get("visible", False)
    debug = node.get("debugLogging", False)

    label = f"{BOLD}{cls}{RESET}"
    if name:
        label += f" {CYAN}{name}{RESET}"
    label += f" {DIM}{w}x{h}{RESET}"
    if not vis:
        label += f" {RED}(hidden){RESET}"
    if debug:
        label += f" {YELLOW}[DEBUG]{RESET}"

    lock = node.get("autoSizeLock", 0)
    if lock > 0:
        label += f" {RED}lock={lock}{RESET}"

    print(f"{prefix}{label}")

    for child in node.get("children", []):
        format_tree(child, indent + 1)


def cmd_ping(client):
    r = client.send({"cmd": "ping"})
    res = r.get("result", {})
    print(f"{GREEN}Connected{RESET} to {BOLD}{res.get('app', '?')}{RESET} "
          f"pid={res.get('pid')} port={res.get('port')} "
          f"v{res.get('version', '?')}")


def cmd_tree(client, depth=10):
    r = client.send({"cmd": "tree", "depth": depth})
    res = r.get("result", {})
    if "error" in res:
        print(f"{RED}Error:{RESET} {res['error']}")
        return
    print(f"{BOLD}{res.get('formCount', 0)} forms{RESET}")
    for form in res.get("forms", []):
        format_tree(form)
        print()


def cmd_forms(client):
    r = client.send({"cmd": "forms"})
    res = r.get("result", {})
    if "error" in res:
        print(f"{RED}Error:{RESET} {res['error']}")
        return
    print(f"{BOLD}{res.get('formCount', 0)} top-level forms:{RESET}")
    for form in res.get("forms", []):
        cls = form.get("class", "?")
        name = form.get("name", "")
        w, h = form.get("width", 0), form.get("height", 0)
        vis = "visible" if form.get("visible") else "hidden"
        cnt = form.get("controlCount", 0)
        print(f"  {CYAN}{name}{RESET} ({cls}) {w}x{h} {vis} children={cnt}")


def cmd_props(client, path):
    r = client.send({"cmd": "props", "path": path})
    res = r.get("result", {})
    if "error" in res:
        print(f"{RED}Error:{RESET} {res['error']}")
        return
    for k, v in sorted(res.items()):
        if k == "children":
            print(f"  {k}: [{len(v)} children]")
        else:
            print(f"  {CYAN}{k}{RESET}: {v}")


def cmd_events(client, since_seq=0, max_events=50):
    r = client.send({"cmd": "events", "since_seq": since_seq, "max": max_events})
    res = r.get("result", {})
    events = res.get("events", [])
    print(f"{BOLD}{res.get('count', 0)} events{RESET} (requested max={max_events})")
    for ev in events:
        ts = ev.get("ts", "?")
        seq = ev.get("seq", 0)
        text = ev.get("text", "")
        short_ts = ts.split("T")[1] if "T" in ts else ts
        print(f"  {DIM}{seq:>8}{RESET} {short_ts} {text}")
    if events:
        return events[-1].get("seq", 0)
    return since_seq


def cmd_stats(client):
    r = client.send({"cmd": "stats"})
    res = r.get("result", {})
    for k, v in sorted(res.items()):
        print(f"  {CYAN}{k}{RESET}: {v}")


def cmd_set_debug(client, path, value):
    r = client.send({"cmd": "set_debug", "path": path, "value": value})
    if "error" in r:
        print(f"{RED}Error:{RESET} {r['error']}")
    else:
        state = "ON" if value else "OFF"
        print(f"{GREEN}DebugLogging={state}{RESET} for {CYAN}{path}{RESET}")


def cmd_watch(client, poll_interval=0.5):
    """Tail events continuously, like 'tail -f'."""
    print(f"{BOLD}Watching events{RESET} (Ctrl+C to stop)...")
    last_seq = 0
    r = client.send({"cmd": "stats"})
    res = r.get("result", {})
    last_seq = res.get("newest_seq", 0)
    print(f"{DIM}Starting from seq {last_seq}{RESET}")

    try:
        while True:
            r = client.send({"cmd": "events", "since_seq": last_seq, "max": 500})
            res = r.get("result", {})
            for ev in res.get("events", []):
                ts = ev.get("ts", "?")
                seq = ev.get("seq", 0)
                text = ev.get("text", "")
                short_ts = ts.split("T")[1] if "T" in ts else ts
                print(f"{DIM}{seq:>8}{RESET} {short_ts} {text}")
                last_seq = seq
            time.sleep(poll_interval)
    except KeyboardInterrupt:
        print(f"\n{DIM}Stopped.{RESET}")


def repl(client):
    """Interactive REPL."""
    print(f"{BOLD}LCL Inspector{RESET} — type 'help' for commands, Ctrl+D to quit")
    cmd_ping(client)
    print()

    try:
        import readline  # noqa: F401 — enables line editing
    except ImportError:
        pass

    while True:
        try:
            line = input(f"{CYAN}lcl>{RESET} ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not line:
            continue

        parts = line.split()
        cmd = parts[0].lower()

        try:
            if cmd in ("help", "?"):
                print(textwrap.dedent("""\
                    ping              Check connection
                    tree [DEPTH]      Control tree (default depth=10)
                    forms             List top-level forms
                    props PATH        Control properties (e.g. MainIDE/StatusBar1)
                    events [MAX]      Recent ring buffer events
                    stats             Ring buffer statistics
                    watch             Tail events (Ctrl+C to stop)
                    debug PATH on|off Toggle DebugLogging
                    raw JSON          Send raw JSON command
                    quit              Exit"""))
            elif cmd == "ping":
                cmd_ping(client)
            elif cmd == "tree":
                depth = int(parts[1]) if len(parts) > 1 else 10
                cmd_tree(client, depth)
            elif cmd == "forms":
                cmd_forms(client)
            elif cmd == "props":
                if len(parts) < 2:
                    print("Usage: props FormName/ControlName")
                else:
                    cmd_props(client, parts[1])
            elif cmd == "events":
                max_ev = int(parts[1]) if len(parts) > 1 else 50
                cmd_events(client, max_events=max_ev)
            elif cmd == "stats":
                cmd_stats(client)
            elif cmd == "watch":
                cmd_watch(client)
            elif cmd == "debug":
                if len(parts) < 3:
                    print("Usage: debug FormName/ControlName on|off")
                else:
                    val = parts[2].lower() in ("on", "true", "1", "yes")
                    cmd_set_debug(client, parts[1], val)
            elif cmd == "raw":
                raw = " ".join(parts[1:])
                r = client.send(json.loads(raw))
                print(json.dumps(r, indent=2))
            elif cmd in ("quit", "exit", "q"):
                break
            else:
                print(f"Unknown command: {cmd}. Type 'help' for commands.")
        except Exception as e:
            print(f"{RED}Error:{RESET} {e}")


def main():
    parser = ArgumentParser(description="LCL Diagnostic Socket Inspector")
    parser.add_argument("--host", default=HOST, help="Server host")
    parser.add_argument("--port", type=int, default=PORT, help="Server port")

    sub = parser.add_subparsers(dest="command")
    sub.add_parser("ping", help="Ping the server")

    p_tree = sub.add_parser("tree", help="Dump control tree")
    p_tree.add_argument("--depth", type=int, default=10)

    sub.add_parser("forms", help="List top-level forms")

    p_props = sub.add_parser("props", help="Control properties")
    p_props.add_argument("path", help="Control path (FormName/ChildName/...)")

    p_events = sub.add_parser("events", help="Ring buffer events")
    p_events.add_argument("--max", type=int, default=50)
    p_events.add_argument("--since", type=int, default=0)

    sub.add_parser("stats", help="Ring buffer statistics")

    p_watch = sub.add_parser("watch", help="Tail events continuously")
    p_watch.add_argument("--interval", type=float, default=0.5)

    p_debug = sub.add_parser("set-debug", help="Toggle DebugLogging")
    p_debug.add_argument("path", help="Control path")
    p_debug.add_argument("value", choices=["on", "off"])

    args = parser.parse_args()

    try:
        client = DiagClient(args.host, args.port)
    except ConnectionRefusedError:
        print(f"{RED}Cannot connect to {args.host}:{args.port}{RESET}")
        print(f"Is Eleazar running with DIAG=1? (DIAG=1 ./build.sh)")
        sys.exit(1)
    except Exception as e:
        print(f"{RED}Connection failed:{RESET} {e}")
        sys.exit(1)

    try:
        if args.command is None:
            repl(client)
        elif args.command == "ping":
            cmd_ping(client)
        elif args.command == "tree":
            cmd_tree(client, args.depth)
        elif args.command == "forms":
            cmd_forms(client)
        elif args.command == "props":
            cmd_props(client, args.path)
        elif args.command == "events":
            cmd_events(client, since_seq=args.since, max_events=args.max)
        elif args.command == "stats":
            cmd_stats(client)
        elif args.command == "watch":
            cmd_watch(client, args.interval)
        elif args.command == "set-debug":
            val = args.value == "on"
            cmd_set_debug(client, args.path, val)
    finally:
        client.close()


if __name__ == "__main__":
    main()
