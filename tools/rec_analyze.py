"""Analyse an Autopilot 3.0 flight recording (/ap3_rec.csv from 'rec on').

Usage: python tools/rec_analyze.py <ap3_rec.csv>

Prints:
  PHANTOM_VELOCITY yes|no  a run of >= 5 s where the hull stands still (speed
                           from position under 0.2 m/s) while the velocity API
                           reads more than 0.5 m/s different
  ALT_P2P <blocks>         largest peak-to-peak of y - tgt_alt over any span of
                           >= 30 s at one altitude target in HOVER/CRUISE/NAV
                           (climbs, descents and lift-off excluded)
  HDG_P2P <deg>            the same for heading - bearing, HOVER only
  HDG_AFTER_PUSHER <share> share of heading corrections starting in HOVER with
                           a pusher RPM change in the 2 s before
  HDG_AFTER_LIFT <share>   the same for any lift corner RPM change
"""
import csv
import math
import sys

LIFT = ("lbp", "lbs", "lsp", "lss")
PUSHERS = ("pp", "ps")


def num(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def wrap180(d):
    d = d % 360.0
    return d - 360.0 if d > 180.0 else d


def load(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k, v in r.items():
            if k not in ("mode", "alt_phase", "nav_phase"):
                r[k] = num(v)
    return [r for r in rows if r["t"] is not None]


def phantom(rows, still=0.2, gap=0.5, span=5.0):
    run_start = None
    for i in range(1, len(rows) - 1):
        a, b, c = rows[i - 1], rows[i], rows[i + 1]
        dt = c["t"] - a["t"]
        if dt <= 0 or None in (a["x"], a["z"], c["x"], c["z"], b["vx"], b["vz"]):
            run_start = None
            continue
        pos = math.hypot(c["x"] - a["x"], c["z"] - a["z"]) / dt
        api = math.hypot(b["vx"], b["vz"])
        if pos < still and abs(api - pos) > gap:
            if run_start is None:
                run_start = b["t"]
            if b["t"] - run_start >= span:
                return True
        else:
            run_start = None
    return False


def spans(rows, keep, key):
    """Runs of consecutive rows that pass keep() with one value of key."""
    out, cur = [], []
    for r in rows:
        if keep(r) and r[key] is not None and (not cur or cur[-1][key] == r[key]):
            cur.append(r)
            continue
        if cur:
            out.append(cur)
        cur = [r] if keep(r) and r[key] is not None else []
    if cur:
        out.append(cur)
    return out


def worst_p2p(rows, keep, key, err, min_span=30.0):
    best = None
    for run in spans(rows, keep, key):
        if run[-1]["t"] - run[0]["t"] < min_span:
            continue
        errs = [err(r) for r in run if err(r) is not None]
        if errs:
            p2p = max(errs) - min(errs)
            best = p2p if best is None else max(best, p2p)
    return best


def changed(rows, i, cols, window=2.0):
    t = rows[i]["t"]
    j = i
    while j > 0 and t - rows[j - 1]["t"] <= window:
        if any(rows[j][c] != rows[j - 1][c] for c in cols):
            return True
        j -= 1
    return False


def after(rows, cols):
    edges = hits = 0
    for i in range(1, len(rows)):
        r, p = rows[i], rows[i - 1]
        if r["mode"] == "HOVER" and p["hdg_active"] == 0 and r["hdg_active"] == 1:
            edges += 1
            if changed(rows, i, cols):
                hits += 1
    return hits / edges if edges else None


def fmt(v, digits=2):
    return "n/a" if v is None else f"{v:.{digits}f}"


def main():
    rows = load(sys.argv[1])
    flying = {"HOVER", "CRUISE", "NAV"}
    moving_alt = {"CLIMB", "DESCEND", "LIFTOFF"}

    def alt_keep(r):
        return r["mode"] in flying and r["alt_phase"] not in moving_alt

    def alt_err(r):
        return None if r["y"] is None else r["y"] - r["tgt_alt"]

    def hdg_err(r):
        return None if r["hdg"] is None else wrap180(r["hdg"] - r["tgt_brg"])

    print("PHANTOM_VELOCITY " + ("yes" if phantom(rows) else "no"))
    print("ALT_P2P " + fmt(worst_p2p(rows, alt_keep, "tgt_alt", alt_err)))
    print("HDG_P2P " + fmt(worst_p2p(rows, lambda r: r["mode"] == "HOVER", "tgt_brg", hdg_err)))
    print("HDG_AFTER_PUSHER " + fmt(after(rows, PUSHERS)))
    print("HDG_AFTER_LIFT " + fmt(after(rows, LIFT)))


if __name__ == "__main__":
    main()
