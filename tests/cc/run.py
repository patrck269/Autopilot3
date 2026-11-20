"""Run the CraftOS-PC smoke scenarios.

Usage: python tests/cc/run.py <path to CraftOS-PC_console.exe> [scenario ...]
Scenarios: both, missing, velocity, nav (default: all four). Each stages the repo into a throwaway
CraftOS data directory with tests/cc/harness.lua as startup.lua, runs the
emulator headless, and prints /report.txt.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


def run(exe: str, scenario: str) -> bool:
    data = pathlib.Path(tempfile.mkdtemp(prefix=f"ap3cc-{scenario}-"))
    # The harness runs as computer 5.
    comp = data / "computer" / "5"
    shutil.copytree(ROOT / "ap3", comp / "ap3")
    (comp / "tests").mkdir(parents=True)
    shutil.copy(ROOT / "tests" / "world.lua", comp / "tests" / "world.lua")
    shutil.copy(ROOT / "startup.lua", comp / "ap3_start.lua")
    shutil.copy(ROOT / "tests" / "cc" / "harness.lua", comp / "startup.lua")
    (comp / "scenario.txt").write_text(scenario)
    try:
        proc = subprocess.run(
            [exe, "--headless", "--directory", str(data), "--id", "5"],
            capture_output=True, text=True, timeout=700,
            cwd=str(pathlib.Path(exe).parent),
        )
        out = proc.stdout
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or b"").decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        print(f"[{scenario}] emulator timed out")
    report = comp / "report.txt"
    print(f"===== scenario {scenario} =====")
    if report.exists():
        text = report.read_text()
        print(text)
        ok = text.rstrip().endswith("ALL CC CHECKS PASSED")
    else:
        print("no report written; emulator output tail:")
        print(out[-3000:])
        ok = False
    shutil.rmtree(data, ignore_errors=True)
    return ok


def main() -> int:
    exe = sys.argv[1]
    scenarios = sys.argv[2:] or ["both", "missing", "velocity", "nav"]
    results = [run(exe, s) for s in scenarios]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
