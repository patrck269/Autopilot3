"""Drive Autopilot 3.0 from the server host through its inbox files.

Usage:
  python tools/ap3_host.py <computer folder> send "<command>" [...]
  python tools/ap3_host.py <computer folder> status
  python tools/ap3_host.py <computer folder> log

<computer folder> is the computer's directory in the world save
(computercraft/computer/<id>). Commands use terminal syntax ('hover',
'alt 510', 'rec on'). The flight loop reads the inbox about once a second;
'send' waits for the replies in /ap3_host.log and prints them.
"""
import os
import pathlib
import sys
import time


def send(folder, lines, timeout=10.0):
    log = folder / "ap3_host.log"
    before = log.stat().st_size if log.exists() else 0
    tmp = folder / "ap3_host.in.tmp"
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, folder / "ap3_host.in")
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if log.exists() and log.stat().st_size > before:
            with open(log, encoding="utf-8", errors="replace") as f:
                f.seek(before)
                got = [ln for ln in f.read().splitlines() if ln.strip()]
            if len(got) >= len(lines):
                print("\n".join(got))
                return 0
        time.sleep(0.25)
    print("no reply: is the computer on and running Autopilot 3.0?")
    return 1


def main():
    folder = pathlib.Path(sys.argv[1])
    action = sys.argv[2]
    if action == "send":
        return send(folder, sys.argv[3:])
    name = {"status": "ap3_host.status", "log": "ap3_host.log"}[action]
    path = folder / name
    print(path.read_text(encoding="utf-8", errors="replace") if path.exists() else f"no {name} yet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
