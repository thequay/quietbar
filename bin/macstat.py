#!/usr/bin/python3
"""macstat: how this Mac is doing, at a glance.

usage: macstat              snapshot (takes about 2 s)
       macstat -w [SECS]    live view, refreshes every SECS seconds (default 3); any key quits
       macstat --popup      live view for the tmux popup (prefix + S)
       macstat --status     memory, swap and Claude usage segment for the tmux status bar
       macstat --model PANE [TTY]
                            model the Claude session in a tmux pane last got an answer from

Memory is each process's footprint and power is macOS's Energy Impact score,
the same numbers Activity Monitor shows. Claude usage and session priorities are added
when the full claude-usage tool sits next to this script (optional). Standard library only,
no sudo.
"""

import glob
import importlib.util
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import termios
import time
import tty

HOME = os.path.expanduser("~")
GIT = os.path.expanduser(os.environ.get("QUIETBAR_PROJECTS_DIR") or "~/git")
BREW_PREFIX = "/opt/homebrew" if os.path.isdir("/opt/homebrew") else "/usr/local"
TMUX = shutil.which("tmux") or BREW_PREFIX + "/bin/tmux"
BREW = shutil.which("brew") or BREW_PREFIX + "/bin/brew"
SUPERVISORCTL = shutil.which("supervisorctl") or BREW_PREFIX + "/bin/supervisorctl"
SUPERVISOR_CONF = os.environ.get("SUPERVISOR_CONF") or BREW_PREFIX + "/etc/supervisord.conf"
SUPERVISOR_STATES = {"RUNNING": "started", "STARTING": "starting", "STOPPED": "stopped",
                     "STOPPING": "stopped", "EXITED": "stopped",
                     "BACKOFF": "error", "FATAL": "error", "UNKNOWN": "error"}

APP_NAMES = {"Google Chrome": "Chrome", "Visual Studio Code": "VS Code"}
DATABASES = {"mysqld", "postgres", "redis-server", "mongod"}
PRESSURE = {1: ("normal", "green", "●"), 2: ("warning", "yellow", "▲"), 4: ("critical", "red", "■")}
UNITS = {"B": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}
COLORS = {"bold": "1", "dim": "2", "red": "31", "green": "32", "yellow": "33", "cyan": "36"}
BAR_WIDTH = 14
LONG_SESSION = 8 * 3600  # Claude sessions open longer than this get a mention


def load_claude_usage():
    """The full claude-usage.py from this folder, or None, so macstat still works without it.
    The small claude-usage.py that ships with quietbar only feeds the menu, so it does not count."""
    here = os.path.join(os.path.dirname(os.path.realpath(__file__)), "claude-usage.py")
    try:
        spec = importlib.util.spec_from_file_location("claude_usage", here)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module if hasattr(module, "session_rows") else None
    except Exception:
        return None


class Style:
    def __init__(self, enabled):
        self.enabled = enabled

    def __call__(self, text, *names):
        if not self.enabled or not names:
            return text
        return "\033[" + ";".join(COLORS[n] for n in names) + "m" + text + "\033[0m"


def run(args, timeout=10):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def start(args):
    try:
        return subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return None


def finish(proc, timeout=20):
    if proc is None:
        return ""
    try:
        return proc.communicate(timeout=timeout)[0]
    except subprocess.TimeoutExpired:
        proc.kill()
        return ""


def parse_size(text):
    m = re.match(r"([\d.]+)([BKMGT])", text)
    return float(m.group(1)) * UNITS[m.group(2)] if m else 0.0


def fmt_size(n):
    return f"{n / (1 << 30):.1f} GB" if n >= 1 << 30 else f"{n / (1 << 20):.0f} MB"


def fmt_age(seconds):
    if seconds >= 86400:
        return f"{seconds // 86400}d {seconds % 86400 // 3600}h"
    if seconds >= 3600:
        return f"{seconds // 3600}h"
    return f"{seconds // 60}m"


def etime_seconds(text):
    days, _, clock = text.rpartition("-")
    hours, minutes, seconds = ([0, 0] + [int(p) for p in clock.split(":")])[-3:]
    return int(days or 0) * 86400 + hours * 3600 + minutes * 60 + seconds


def short_path(path):
    if path == HOME:
        return "~"
    if path.startswith(GIT + "/"):
        return path[len(GIT) + 1:]
    if path.startswith(HOME + "/"):
        return "~/" + path[len(HOME) + 1:]
    return path


def natural_key(text):
    return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", text)]


def sysctl(*keys):
    values = {}
    for line in run(["/usr/sbin/sysctl"] + list(keys)).splitlines():
        key, _, value = line.partition(": ")
        values[key] = value.strip()
    return values


def swap_usage(text):
    found = dict(re.findall(r"(total|used) = ([\d.]+)M", text))
    return float(found.get("used", 0)) * UNITS["M"], float(found.get("total", 0)) * UNITS["M"]


def read_memory(vm_stat, internal):
    """Memory the way Activity Monitor adds it up, in bytes: app (anonymous pages less purgeable),
    wired, compressed (what the compressor occupies), cached files (file-backed plus purgeable).
    `internal` is sysctl vm.page_pageable_internal_count. None if vm_stat can't be read."""
    page = re.search(r"page size of (\d+) bytes", vm_stat)
    if not page or not internal.isdigit():
        return None

    def pages(label):
        m = re.search(rf"^{label}:\s+(\d+)", vm_stat, re.M)
        return int(m.group(1)) if m else 0

    size = int(page.group(1))
    purgeable = pages("Pages purgeable")
    app = max(0, int(internal) - purgeable) * size
    wired = pages("Pages wired down") * size
    compressed = pages("Pages occupied by compressor") * size
    return {"app": app, "wired": wired, "compressed": compressed,
            "used": app + wired + compressed,
            "cached": (pages("File-backed pages") + purgeable) * size}


def app_group(path):
    """Group a process by the app it belongs to: Chrome's 28 helpers count as one Chrome."""
    base = os.path.basename(path)
    if base == "claude":
        return "Claude"
    if base in DATABASES:
        return "Databases"
    if base.startswith(("php", "nginx")):
        return "PHP/nginx"
    if base.startswith(("mds", "mdworker")):
        return "Spotlight"
    bundle = re.search(r"([^/]+)\.app/", path)  # the outermost .app in the path
    if bundle:
        return APP_NAMES.get(bundle.group(1), bundle.group(1))
    if re.match(r"(com|io|org|net)\.[\w-]+\.", base):  # io.tailscale.ipn… -> Tailscale
        return base.split(".")[1].capitalize()
    return base


def read_top(output):
    """Parse the second `top` sample; the first has no CPU or power figures yet."""
    sample = output.split("Processes:")[-1]
    head, _, table = sample.partition("\nPID")
    rows = {}
    for line in table.splitlines()[1:]:
        parts = line.split(None, 4)
        if len(parts) < 5 or not parts[0].isdigit():
            continue
        try:
            rows[int(parts[0])] = {"cpu": float(parts[1]), "power": float(parts[2]),
                                   "mem": parse_size(parts[3]), "name": parts[4].strip()}
        except ValueError:
            continue
    cpu = re.search(r"CPU usage: ([\d.]+)% user, ([\d.]+)% sys", head)
    return rows, {"cpu_user": float(cpu.group(1)) if cpu else 0.0,
                  "cpu_sys": float(cpu.group(2)) if cpu else 0.0}


def read_ps():
    procs = {}
    for line in run(["/bin/ps", "-Ao", "pid=,ppid=,tty=,etime=,comm="]).splitlines():
        parts = line.split(None, 4)
        if len(parts) == 5:
            procs[int(parts[0])] = {"tty": parts[2], "etime": parts[3], "path": parts[4]}
    return procs


def tmux_panes():
    fmt = "#{pane_tty}\t#{session_name}\t#{window_index}.#{pane_index}\t#{pane_id}\t#{session_attached}"
    panes = []
    for line in run([TMUX, "list-panes", "-a", "-F", fmt]).splitlines():
        parts = line.split("\t")
        if len(parts) == 5:
            tty_path, session, index, pane_id, attached = parts
            panes.append({"tty": tty_path.replace("/dev/", ""), "label": f"{session}:{index}",
                          "session": session, "id": pane_id, "attached": attached != "0"})
    return panes


def current_pane():
    """The pane macstat runs in, or in a popup (no pane of its own) the active pane."""
    pane = os.environ.get("TMUX_PANE", "")
    if pane.startswith("%"):
        return pane
    if os.environ.get("TMUX"):
        return run([TMUX, "display-message", "-p", "#{pane_id}"]).strip()
    return ""


def claude_sessions(procs, top_rows, panes):
    pids = [pid for pid, p in procs.items() if os.path.basename(p["path"]) == "claude"]
    if not pids:
        return []
    args = {}
    for line in run(["/bin/ps", "-o", "pid=,args=", "-p", ",".join(map(str, pids))]).splitlines():
        pid, _, rest = line.strip().partition(" ")
        if pid.isdigit():
            args[int(pid)] = rest
    # Keep interactive sessions: ones in a terminal, plus the VS Code extension's.
    pids = [pid for pid in pids
            if "--chrome-native-host" not in args.get(pid, "")
            and (procs[pid]["tty"] != "??" or "/.vscode/extensions/" in procs[pid]["path"])]
    if not pids:
        return []

    cwds, pid = {}, None
    for line in run(["/usr/sbin/lsof", "-a", "-d", "cwd", "-Fn", "-p", ",".join(map(str, pids))]).splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid:
            cwds[pid] = line[1:]

    by_tty = {p["tty"]: p for p in panes}
    sessions = []
    for pid in pids:
        proc, row = procs[pid], top_rows.get(pid, {})
        pane = by_tty.get(proc["tty"])
        if pane:
            label, pane_id = pane["label"], pane["id"]
        else:
            label, pane_id = ("VS Code" if proc["tty"] == "??" else proc["tty"]), ""
        sessions.append({"pid": pid, "pane": label, "pane_id": pane_id,
                         "project": short_path(cwds.get(pid, "?")),
                         "age": etime_seconds(proc["etime"]),
                         "cpu": row.get("cpu", 0.0), "mem": row.get("mem", 0.0)})
    return sorted(sessions, key=lambda s: natural_key(s["pane"]))


def read_supervisor(output):
    """Supervisor programs by group, or from its config, all stopped, when supervisord is down."""
    programs = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] in SUPERVISOR_STATES:
            group = parts[0].split(":")[0]  # app:app_00 -> app
            state = SUPERVISOR_STATES[parts[1]]
            if group not in programs or state == "error":
                programs[group] = (state, parts[1] if state == "error" else "")
    if programs:
        return programs, True
    for path in [SUPERVISOR_CONF] + sorted(glob.glob(os.path.join(os.path.dirname(SUPERVISOR_CONF), "supervisor.d", "*.ini"))):
        try:
            with open(path) as f:
                names = re.findall(r"^\[program:([^\]]+)\]", f.read(), re.M)
        except OSError:
            continue
        for name in names:
            programs[name] = ("stopped", "supervisor off")
    return programs, False


def read_services(brew_output, supervisor):
    """Homebrew services and supervisor programs. A brew service that supervisor also runs
    (mailpit) is left out: supervisor owns it."""
    try:
        brew = json.loads(brew_output)
    except ValueError:
        brew = []
    services = []
    for s in brew:
        if not isinstance(s, dict) or s.get("name") in supervisor:
            continue
        status = s.get("status", "")
        state = {"started": "started", "scheduled": "started", "error": "error"}.get(status, "stopped")
        services.append({"name": s.get("name", "?"), "runner": "brew", "state": state,
                         "detail": f"exit {s.get('exit_code')}" if state == "error" else ""})
    for name, (state, detail) in sorted(supervisor.items()):
        services.append({"name": name, "runner": "supervisor", "state": state, "detail": detail})
    return services


def collect():
    brew = start([BREW, "services", "list", "--json"]) if os.path.exists(BREW) else None
    supervisorctl = (start([SUPERVISORCTL, "-c", SUPERVISOR_CONF, "status"])
                     if os.path.exists(SUPERVISORCTL) else None)
    top = start(["/usr/bin/top", "-l", "2", "-s", "1", "-n", "1000", "-stats", "pid,cpu,power,mem,command"])
    info = sysctl("hw.memsize", "hw.ncpu", "machdep.cpu.brand_string", "kern.boottime",
                  "kern.memorystatus_vm_pressure_level", "vm.swapusage", "vm.page_pageable_internal_count")
    top_rows, totals = read_top(finish(top))
    memory = read_memory(run(["/usr/bin/vm_stat"]), info.get("vm.page_pageable_internal_count", ""))
    procs = read_ps()
    panes = tmux_panes()

    skip = {os.getpid(), top.pid if top else 0}
    groups = {}
    for pid, row in top_rows.items():
        if pid in skip:
            continue
        g = groups.setdefault(app_group(procs.get(pid, {}).get("path") or row["name"]),
                              {"mem": 0.0, "cpu": 0.0, "power": 0.0})
        g["mem"] += row["mem"]
        g["cpu"] += row["cpu"]
        g["power"] += row["power"]

    boot = re.search(r"sec = (\d+)", info.get("kern.boottime", ""))
    swap_used, swap_total = swap_usage(info.get("vm.swapusage", ""))
    here = current_pane()
    supervisor, supervisor_up = read_supervisor(finish(supervisorctl))
    sessions = {}
    for p in panes:
        s = sessions.setdefault(p["session"], {"panes": 0, "attached": p["attached"]})
        s["panes"] += 1

    return {
        "host": socket.gethostname().split(".")[0],
        "chip": info.get("machdep.cpu.brand_string", "Mac"),
        "ram": float(info.get("hw.memsize", 0) or 1),
        "ncpu": int(info.get("hw.ncpu", 0) or 1),
        "uptime": int(time.time()) - int(boot.group(1)) if boot else 0,
        "pressure": int(info.get("kern.memorystatus_vm_pressure_level", 0) or 0),
        "swap_used": swap_used, "swap_total": swap_total,
        "load": os.getloadavg()[0],
        **totals,
        "memory": memory,
        "groups": groups,
        "procs": {os.path.basename(p["path"]) for p in procs.values()},
        "claude": claude_sessions(procs, top_rows, panes),
        "tmux": sessions,
        "here": here,
        "here_label": next((p["label"] for p in panes if p["id"] == here), ""),
        "services": read_services(finish(brew), supervisor),
        "supervisor_up": supervisor_up,
    }


def tips(d):
    out = []
    groups = sorted(d["groups"].items(), key=lambda kv: -kv[1]["mem"])
    if d["pressure"] >= 2 and groups:
        name, g = groups[0]
        out.append(f"memory {PRESSURE[d['pressure']][0]}: {name} uses the most ({fmt_size(g['mem'])})")
    if d["swap_total"] and d["swap_used"] / d["swap_total"] > 0.5:
        out.append(f"swap {fmt_size(d['swap_used'])} of {fmt_size(d['swap_total'])} used; "
                   f"a restart clears it (up {fmt_age(d['uptime'])})")
    if d["load"] > d["ncpu"]:
        busiest = max(d["groups"].items(), key=lambda kv: kv[1]["cpu"])[0]
        out.append(f"load {d['load']:.1f} is above {d['ncpu']} cores; {busiest} is busiest")
    for s in d["claude"]:
        if s["age"] >= LONG_SESSION:
            out.append(f"{s['pane']} ({s['project']}) has been open {fmt_age(s['age'])}, {fmt_size(s['mem'])}")
    if {"mysqld", "postgres"} <= d["procs"]:
        out.append("mysql and postgres both running: svc stop the one you don't need")
    for svc in d["services"]:
        if svc["state"] == "error":
            out.append(f"{svc['name']} failed to start ({svc['detail']})")
    supervised = [x["name"] for x in d["services"] if x["runner"] == "supervisor"]
    if supervised and not d["supervisor_up"]:
        out.append(f"supervisor is off, so {', '.join(supervised)} aren't running: svc start supervisor")
    spotlight = d["groups"].get("Spotlight", {}).get("cpu", 0)
    if spotlight > 25:
        out.append(f"Spotlight is indexing ({spotlight:.0f}% cpu)")
    return out


def bar(share, s, color):
    filled = max(0, min(BAR_WIDTH, round(share * BAR_WIDTH)))
    if share > 0 and filled == 0:
        filled = 1
    return s("█" * filled, color) + s("░" * (BAR_WIDTH - filled), "dim")


ANSI_RE = re.compile(r"\033\[[0-9;]*m")
_CTX = {}    # session id -> (transcript path, (size, mtime), context tokens)


def vlen(text):
    """Printed width of a string that may hold colour codes."""
    return len(ANSI_RE.sub("", text))


def side_by_side(left, right, width, gap=3):
    rows = []
    for i in range(max(len(left), len(right))):
        l = left[i] if i < len(left) else ""
        r = right[i] if i < len(right) else ""
        rows.append(l + " " * (width - vlen(l) + gap) + r if r else l)
    return rows


def session_ctx_tokens(cu, sid):
    """Context size in tokens of a session's last API call, read from its transcript (the state file
    only keeps the percentage). Re-read only when the transcript has changed. None if unknown."""
    try:
        path = _CTX.get(sid, (None,))[0]
        if not path:
            found = glob.glob(os.path.join(cu.PROJECTS, "*", f"{sid}.jsonl"))
            if not found:
                return None
            path = found[0]
        st = os.stat(path)
        stamp = (st.st_size, st.st_mtime)
        if sid in _CTX and _CTX[sid][1] == stamp:
            return _CTX[sid][2]
        call = cu.last_call(path)
        _CTX[sid] = (path, stamp, call[1] if call else None)
        return _CTX[sid][2]
    except Exception:
        cu.log_error("macstat ctx")
        return None


def mem_block(d, s):
    gb = d["ram"] / (1 << 30)
    name, color, sym = PRESSURE.get(d["pressure"], ("unknown", "dim", "?"))
    head = f"{s('MEM', 'bold')}  {s(sym + ' ' + name, color)}"
    if d["memory"]:  # used is app + wired + compressed, as in Activity Monitor; not top's total minus free
        head += f" · {d['memory']['used'] / (1 << 30):.1f}/{gb:.0f} GB used · {d['memory']['cached'] / (1 << 30):.1f} cached"
    if d["swap_total"]:
        head += f" · swap {d['swap_used'] / (1 << 30):.1f}/{d['swap_total'] / (1 << 30):.1f} GB"
    lines = [head, s(f"{'by app':<11} {'':<{BAR_WIDTH}} {'size':>7} {'ram':>4}", "dim")]
    for label, g in sorted(d["groups"].items(), key=lambda kv: -kv[1]["mem"])[:6]:
        if label == "Claude" and d["claude"]:
            label = f"Claude ×{len(d['claude'])}"
        share = g["mem"] / d["ram"]
        lines.append(f"{label[:11]:<11} {bar(share, s, 'cyan')} {fmt_size(g['mem']):>7} {share:>4.0%}")
    return lines


def cpu_block(d, s):
    head = f"{s('CPU', 'bold')}  load {d['load']:.1f}/{d['ncpu']} · user {d['cpu_user']:.0f}% sys {d['cpu_sys']:.0f}%"
    lines = [head, s(f"{'by energy':<11} {'':<{BAR_WIDTH}} {'impact':>6} {'cpu':>5}", "dim")]
    by_power = [kv for kv in sorted(d["groups"].items(), key=lambda kv: -kv[1]["power"])[:5]
                if kv[1]["power"] > 0]
    most = by_power[0][1]["power"] if by_power else 1
    for label, g in by_power:
        lines.append(f"{label[:11]:<11} {bar(g['power'] / most, s, 'yellow')} {g['power']:>6.1f} {g['cpu']:>4.0f}%")
    return lines


def render(d, s):
    cols = shutil.get_terminal_size((100, 24)).columns
    gb = d["ram"] / (1 << 30)
    lines = [s(f"{d['host']} · {d['chip']} · {gb:.0f} GB · up {fmt_age(d['uptime'])}", "bold")
             + s(f"   {time.strftime('%H:%M')}", "dim")]
    if d["tmux"]:
        parts = [f"{n} ({t['panes']} panes{', attached' if t['attached'] else ''})"
                 for n, t in sorted(d["tmux"].items())]
        lines.append(f"{s('TMUX', 'bold')} " + " · ".join(parts))

    mem, cpu = mem_block(d, s), cpu_block(d, s)
    lines.append("")
    left = max(vlen(l) for l in mem)
    lines += side_by_side(mem, cpu, left) if cols >= left + 3 + max(vlen(l) for l in cpu) else mem + [""] + cpu

    cu = load_claude_usage()
    usage = cu.usage_lines(s, BAR_WIDTH, proj=cu.PROJ_TTL, compact=True) if cu else []
    if usage:
        lines += [""] + usage

    if d["claude"]:
        # Priority and context size (tokens of the last call, from the transcript) per session.
        now = int(time.time())
        seen = {x.get("claude_pid"): x for x in cu.session_rows(now)} if cu else {}
        cfg = cu.config() if cu else {}
        lines.append("")
        w_pane = max(len(x["pane"]) for x in d["claude"]) + 2
        w_proj = min(24, max(len("project"), *(len(x["project"]) for x in d["claude"])))
        lines.append(s(f"{'pane':<{w_pane}}  {'project':<{w_proj}}  {'prio':<6}  {'ctx':>5}  "
                       f"{'age':>6}  {'cpu':>4}  {'mem':>6}  model", "dim"))
        for x in d["claude"]:
            here = x["pane_id"] and x["pane_id"] == d["here"]
            pane = f"{x['pane'] + (' ◀' if here else ''):<{w_pane}}"
            age = f"{fmt_age(x['age']):>6}"
            info = seen.get(x["pid"], {})
            prio = f"{info.get('priority', '-'):<6}"
            tokens = session_ctx_tokens(cu, info["id"]) if cu and info.get("id") else None
            if tokens:
                ctx = cu.fmt_n(tokens)
                ctx = s(f"{ctx:>5}", cu.ctx_color(tokens, cfg)) if cu.ctx_color(tokens, cfg) else f"{ctx:>5}"
            else:
                ctx = f"{info['ctx']:.0f}%".rjust(5) if info.get("ctx") is not None else f"{'-':>5}"
            path = _CTX.get(info.get("id"), (None,))[0]
            served = cu.served_model(path) if cu and path else None
            asked = info.get("model_id")
            if not served:
                model = s("-", "dim")
            elif cu.model_differs(asked, served):
                model = s(f"{cu.short_model(asked)}≠{served}", "red", "bold")
            else:
                model = s(served, "yellow") if served == "?" else s(served, "cyan")
            lines.append("  ".join([
                s(pane, "bold", "cyan") if here else pane,
                f"{x['project'][:w_proj]:<{w_proj}}",
                s(prio, {"high": "cyan", "low": "yellow"}.get(info.get("priority"), "dim")),
                ctx,
                s(age, "yellow") if x["age"] >= LONG_SESSION else age,
                f"{x['cpu']:>3.0f}%",
                f"{fmt_size(x['mem']):>6}",
                model]))
            # This session's running subagents, one indented row each: type, description, served model.
            for sub in (cu.running_subagents(path, served) if cu and path and served else []):
                mark = (s(f"{sub['expected']}≠{sub['served']}", "red", "bold") if sub["bad"]
                        else s(sub["served"], "yellow") if sub["served"] == "?" else s(sub["served"], "cyan"))
                head = " " * (w_pane + 2) + "└ " + f"{sub['type'][:13]:<13}" + " "
                width = min(30, max(8, cols - vlen(head) - vlen(mark) - 2))
                desc = sub["desc"] if len(sub["desc"]) <= width else sub["desc"][:width - 1] + "…"
                lines.append(s(head, "dim") + f"{desc:<{width}}  " + mark)

    lines += ["", s("TIPS", "bold")]
    found = tips(d)
    lines += ["• " + t for t in found] if found else [s("• nothing obvious", "green")]
    return "\n".join(lines)


def pane_model(pane_id, tty="", why=None):
    """The model the Claude session in a tmux pane last got an answer from, as the API reported it
    in the transcript's newest assistant entry (not /model, settings or flags, which only say what
    was asked for). None when the pane runs no Claude; "?" when the session can't be pinned down.

    Pane -> process: the one `claude` on the pane's tty. Process -> session: claude-usage's session
    record for that pid, written by the status line and the SessionStart hook, which must name this
    pane and be newer than the process (a reused pid gives an older record). The newest such record
    wins (/clear and /resume start a new session id in the same process). Session -> model: the
    last real assistant entry of ~/.claude/projects/*/<id>.jsonl. Anything missing or ambiguous is
    "?", never a guess. `why`, a list, gets the reason for a "?"."""
    def unsure(reason):
        if why is not None:
            why.append(reason)
        return "?"

    cu = load_claude_usage()
    if not tty:
        tty = run([TMUX, "display-message", "-p", "-t", pane_id, "#{pane_tty}"]).strip()
    tty = tty.replace("/dev/", "")
    if not tty:
        return None
    procs = []
    for line in run(["/bin/ps", "-t", tty, "-o", "pid=,etime=,comm="]).splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and os.path.basename(parts[2]) == "claude":
            procs.append((int(parts[0]), etime_seconds(parts[1])))
    if not procs:
        return None
    if not cu:
        return unsure("claude-usage.py not found")
    now = time.time()
    found = []  # (record) for every claude process on the tty that has a record for this pane
    for pid, age in procs:
        records = [x for x in cu.all_sessions()
                   if x.get("claude_pid") == pid and x.get("pane") == pane_id
                   and x.get("seen_at", 0) >= now - age - 5]
        if records:
            found.append(max(records, key=lambda x: x["seen_at"]))
    if len(found) != 1:
        return unsure(f"{len(found)} of {len(procs)} claude processes on {tty} have a session record for {pane_id}")
    paths = glob.glob(os.path.join(cu.PROJECTS, "*", found[0]["id"] + ".jsonl"))
    if len(paths) != 1:
        return unsure(f"{len(paths)} transcripts for session {found[0]['id']}")
    try:
        call = cu.last_call(paths[0])
    except Exception:
        cu.log_error("macstat model")
        return unsure("transcript unreadable")
    return cu.short_model(call[2]) if call and call[2] else unsure("no assistant entry yet")


def model_segment(pane_id, tty=""):
    """tmux status segment for the pane's model, with its trailing separator; empty when the pane
    runs no Claude."""
    why = []
    model = pane_model(pane_id, tty, why)
    if os.environ.get("MACSTAT_DEBUG"):
        print(f"macstat --model {pane_id}: {model or 'no claude'} {why}", file=sys.stderr)
    if not model:
        return ""
    return "#[fg=yellow]?#[default] | " if model == "?" else f"#[fg=cyan,bold]{model}#[default] | "


def status():
    """One tmux status segment. Cheap: tmux runs it every status-interval."""
    info = sysctl("kern.memorystatus_vm_pressure_level", "vm.swapusage")
    level = int(info.get("kern.memorystatus_vm_pressure_level", 0) or 0)
    name, color, sym = PRESSURE.get(level, ("?", "default", "?"))
    used, _ = swap_usage(info.get("vm.swapusage", ""))
    line = f"#[fg={color}]{sym} mem {name}#[default] · swap {used / (1 << 30):.1f}G"
    cu = load_claude_usage()
    if cu:
        try:
            cu.tick()  # tells you once when a held Claude prompt can go
            segment = cu.status_segment()
        except Exception:
            segment = ""
        if segment:
            line += f" | {segment}"
    print(line)


def live(interval, footer):
    interactive = sys.stdin.isatty()
    if interactive:
        fd = sys.stdin.fileno()
        saved = termios.tcgetattr(fd)
        tty.setcbreak(fd)
    out, s = sys.stdout, Style(True)
    out.write("\033[?25l\033[2J\033[H  collecting…")
    out.flush()
    try:
        while True:
            screen = (render(collect(), s) + "\n\n" + s(footer, "dim")).split("\n")
            rows = shutil.get_terminal_size().lines
            if rows > 1:  # 0 when the terminal doesn't say
                screen = screen[:rows - 1]
            out.write("\033[H" + "\033[K\n".join(screen) + "\033[K\033[J")
            out.flush()
            if not interactive:
                time.sleep(interval)
            elif select.select([sys.stdin], [], [], interval)[0]:
                os.read(fd, 32)
                break
    except KeyboardInterrupt:
        pass
    finally:
        if interactive:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        out.write("\033[?25h\n")
        out.flush()


def main(argv):
    if argv == ["--status"]:
        status()
    elif argv[:1] == ["--model"] and 2 <= len(argv) <= 3:
        print(model_segment(*argv[1:]))
    elif argv == ["--popup"]:
        live(3, "any key closes")
    elif argv[:1] in (["-w"], ["--watch"]) and len(argv) <= 2:
        try:
            interval = float(argv[1]) if len(argv) == 2 else 3.0
        except ValueError:
            sys.exit(__doc__)
        live(max(interval, 1.0), f"refreshing every {interval:g}s · any key quits")
    elif argv in (["-h"], ["--help"], ["help"]):
        print(__doc__.strip())
    elif argv:
        sys.exit(__doc__.strip())
    else:
        print(render(collect(), Style(sys.stdout.isatty())))


if __name__ == "__main__":
    main(sys.argv[1:])
