#!/usr/bin/python3
"""claude-usage: records Claude plan usage (5-hour and weekly) for the Claude agents menu bar item.

usage: claude-usage.py                 print the last reading of every profile
       claude-usage.py --statusline    Claude Code status line: reads the session JSON on stdin,
                                       records the plan usage in the cache, prints "5h 6% · wk 13%"

Claude Code hands its status line a "rate_limits" field with the plan usage. This script is that
status line, so the numbers are as fresh as the last response in any Claude session on this Mac.
Nothing calls an API, and no token or login is read. Set it up once in ~/.claude/settings.json:

  "statusLine": { "type": "command", "command": "/path/to/claude-usage.py --statusline" }

Set it up in the settings.json of every Claude profile you want usage for (~/.claude/settings.json,
~/.claude-work/settings.json, ...). Already have a status line command? Pipe the JSON through this
script first, or call it from yours and ignore its output.

Each profile gets its own reading, because each can be a different account. The profile is the
folder the session's transcript is under, else CLAUDE_CONFIG_DIR, else ~/.claude. Cache:
~/.cache/claude-usage/usage.json for ~/.claude, ~/.cache/claude-usage/profiles/<name>/usage.json for
the others (CLAUDE_USAGE_CACHE moves it all). Each file records its profile folder as "config_dir".
Standard library only.
"""

import fcntl
import glob
import hashlib
import json
import os
import re
import sys
import tempfile
import time

CACHE = os.environ.get("CLAUDE_USAGE_CACHE") or os.path.join(os.path.expanduser("~"), ".cache", "claude-usage")
DEFAULT_PROFILE = os.path.realpath(os.path.join(os.path.expanduser("~"), ".claude"))
WINDOWS = {"five_hour": ("5h", 5 * 3600), "seven_day": ("week", 7 * 86400)}
SAME_WINDOW = 600  # reset times this close belong to the same window
STALE = 15 * 60    # readings older than this get an "as of" note
BAR = 20


def profile_dir(data):
    """The Claude profile folder a status line call belongs to."""
    m = re.match(r"(.+?)/projects/[^/]+/", (data.get("transcript_path") if isinstance(data, dict) else "") or "")
    folder = m.group(1) if m else os.environ.get("CLAUDE_CONFIG_DIR") or DEFAULT_PROFILE
    return os.path.realpath(os.path.expanduser(folder))


def cache_dir_for(config_dir):
    if config_dir == DEFAULT_PROFILE:
        return CACHE
    name = re.sub(r"[^A-Za-z0-9_.-]", "-", os.path.basename(config_dir).lstrip(".")) or "profile"
    return os.path.join(CACHE, "profiles", f"{name}-{hashlib.sha1(config_dir.encode()).hexdigest()[:6]}")


def read_usage(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def merge(limits, now, config_dir):
    """Fold one session's rate_limits into the shared reading. Within a window use only grows, so
    the higher number is the newer one; a later reset time is a newer window. That keeps an idle
    session's old numbers from overwriting a busy session's."""
    cache = cache_dir_for(config_dir)
    usage_file = os.path.join(cache, "usage.json")
    os.makedirs(cache, exist_ok=True)
    with open(os.path.join(cache, ".usage.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        usage = read_usage(usage_file)
        changed = False
        for key in WINDOWS:
            new = (limits or {}).get(key) or {}
            if new.get("used_percentage") is None or not new.get("resets_at"):
                continue
            new = {"used": float(new["used_percentage"]), "resets_at": int(new["resets_at"])}
            old = usage.get(key)
            if (not old
                    or new["resets_at"] > old["resets_at"] + SAME_WINDOW
                    or (abs(new["resets_at"] - old["resets_at"]) <= SAME_WINDOW and new["used"] > old["used"])):
                usage[key] = new
                changed = True
        if changed:
            usage["seen_at"] = now
            usage["config_dir"] = config_dir
            fd, tmp = tempfile.mkstemp(dir=cache, suffix=".tmp")
            with os.fdopen(fd, "w") as f:
                json.dump(usage, f, indent=1)
            os.replace(tmp, usage_file)
        return usage


def window(usage, key, now):
    """A window's reading, or zero use once its reset time has passed. None when unknown."""
    w = usage.get(key)
    if not isinstance(w, dict) or "used" not in w or "resets_at" not in w:
        return None
    if w["resets_at"] <= now:
        return {"used": 0.0, "resets_at": None}
    return w


def span(seconds):
    seconds = max(0, int(seconds))
    if seconds >= 86400:
        return f"{seconds // 86400}d {seconds % 86400 // 3600}h"
    if seconds >= 3600:
        return f"{seconds // 3600}h {seconds % 3600 // 60:02d}m"
    return f"{seconds // 60}m"


def when(ts, now):
    t = time.localtime(ts)
    same_day = time.strftime("%F", t) == time.strftime("%F", time.localtime(now))
    return time.strftime("%H:%M" if same_day else "%a %H:%M", t) + f" (in {span(ts - now)})"


def week_gone(w, now):
    """Share of the weekly window already gone, 0 to 100."""
    length = WINDOWS["seven_day"][1]
    return max(0.0, min(100.0, 100.0 * (now - (w["resets_at"] - length)) / length))


def caches():
    """Every recorded reading, the default profile's first."""
    files = [os.path.join(CACHE, "usage.json")] + sorted(glob.glob(os.path.join(CACHE, "profiles", "*", "usage.json")))
    return [(read_usage(f).get("config_dir") or DEFAULT_PROFILE, read_usage(f)) for f in files if os.path.exists(f)]


def report(now):
    readings = [(c, u) for c, u in caches() if any(k in u for k in WINDOWS)]
    if not readings:
        script = os.path.realpath(__file__)
        print("No Claude usage recorded yet.")
        print("Claude Code reports it to its status line. To record it, add this to the settings.json of each Claude profile:")
        print(f'"statusLine": {{ "type": "command", "command": "{script} --statusline" }}')
        print("The numbers appear after the next Claude response.")
        return
    for config_dir, usage in readings:
        age = now - usage.get("seen_at", now)
        home = os.path.expanduser("~")
        shown = "~" + config_dir[len(home):] if config_dir.startswith(home + "/") else config_dir
        print(f"CLAUDE USAGE {shown}  " + (f"as of {span(age)} ago" if age > STALE else "from the last Claude response"))
        for key, (label, _) in WINDOWS.items():
            w = window(usage, key, now)
            if not w:
                continue
            filled = max(0, min(BAR, round(w["used"] / 100 * BAR)))
            note = f"resets {when(w['resets_at'], now)}" if w["resets_at"] else "reset, nothing used since"
            if key == "seven_day" and w["resets_at"]:
                note += f" · {week_gone(w, now):.0f}% of week gone"
            print(f"{label:<12}{'█' * filled}{'░' * (BAR - filled)} {w['used']:>3.0f}%  {note}")


def statusline(now):
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    usage = merge(data.get("rate_limits") if isinstance(data, dict) else None, now, profile_dir(data))
    parts = []
    for key, label in (("five_hour", "5h"), ("seven_day", "wk")):
        w = window(usage, key, now)
        if w:
            parts.append(f"{label} {w['used']:.0f}%")
    print(" · ".join(parts))


def main(argv):
    now = int(time.time())
    if argv == ["--statusline"]:
        statusline(now)
    elif not argv:
        report(now)
    else:
        print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
