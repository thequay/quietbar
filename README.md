# quietbar

One quiet SwiftBar menu bar item for your whole Mac.

Disk, memory, services, ports, scheduled tasks, app presets and Claude usage each become one summary row, with their full menu one level down. The menu bar shows only an icon while everything is fine. When something needs attention, a short label appears next to the icon.

This repo is the whole setup: the wrapper (`quietbar.1m.rb`), the plugins it wraps, one separate plugin for Claude agents (`claude-agents.15s.rb`), the helper scripts they call, a ready-made config and an installer. The wrapper also works on its own, with any SwiftBar plugins, without changing them. See [Config](#config).

## What it looks like

All clear, the menu bar is just the icon:

```
[grid icon]
```

The dropdown has one row per plugin:

```
Mac — 106 GB free
Services — 3 running
Ports — 16 listening
Tasks — all on time
Loadout — focus
Claude — 5h 7% · wk 14%
-------------------------------
Refresh
```

Pointing at a row opens that plugin's own menu. For Mac:

```
Mac — 106 GB free  >  Disk    ███████████░░░░░░░░░  53% used
                      106.4 GB free of 228.3 GB (data volume)
                      Memory  ████████████████░░░░  6.4 GB of 8.0 GB · pressure normal
                      Swap    ██████████░░░░░░░░░░  1.0 GB of 2.0 GB
                      CPU     ███████░░░░░░░░░░░░░  load 2.8 of 8 cores (5 min)
                      Battery, Time Machine, uptime, biggest dev folders, Open Activity Monitor
```

When a plugin signals trouble, the worst problem shows next to the icon, with `+N` for the others. Here the disk is nearly full and a task failed:

```
[grid icon] disk 9G +1
```

```
Mac — 9 GB free
Tasks — 1 failed
```

The icon and label turn red if any alert is critical, otherwise amber.

## What's included

| Row | What it shows | Needs |
| --- | --- | --- |
| Mac (`mac-health`) | Disk, memory and swap, CPU load, battery, Time Machine, uptime, the dev folders that grew. Alerts on low disk or battery and an old backup. | python3 |
| Services (`brew-services`) | Homebrew services: start, stop, restart, hide. Alerts on a service in the error state. | Homebrew |
| Ports (`ports`) | What listens on TCP ports and who owns it, stop it, open it, find what holds a folder open. | |
| Tasks (`tasks`) | Scheduled tasks (launchd agents and cron): what runs when, what ran last, what is overdue or failed. Also a `task` command. | |
| Loadout (`loadout`) | Presets for what runs: pick one and services, launchd jobs and apps start or stop to match. | |
| Claude (`claude-usage`) | Claude plan usage, 5-hour and weekly. Alerts from 85%. | python3, one setting in Claude Code, see [Claude usage](#claude-usage) |
| Claude agents (`claude-agents.15s.rb`), its own menu bar item | How many Claude Code instances are running, grouped by Claude profile. See [Claude agents](#claude-agents). | |
| Git (`git-status`), off by default | Dirty, unpushed and stashed repos under your projects folder. | git |
| Dev (`dev-processes`), off by default | Running dev processes (node first) and launchd jobs, with a stop button. | |

The shared menu helper is `lib/menu_kit.rb`. Helper scripts in `bin/`: `svc.sh` (list and control Homebrew and supervisor services), `macstat.py` (memory and CPU per app), `claude-usage.py`, `task`, `task-run.sh` and `trash-rm.sh` (used by Tasks).

## Install

You need macOS, [SwiftBar](https://swiftbar.app) and Ruby 2.6 or newer (the one macOS ships works; nothing outside the standard library is used). Mac and Claude rows also need the Command Line Tools (`xcode-select --install`), Services needs [Homebrew](https://brew.sh). `install.sh` checks and tells you what is missing. It installs nothing itself.

Get the repo (clone it, or download the zip from GitHub), then run the installer from inside it:

```sh
cd quietbar
./install.sh
```

What it does:

- Copies `quietbar.1m.rb` into SwiftBar's current plugin folder (or `~/SwiftBar/Plugins` if none is set) and everything it wraps into a hidden `.quietbar/` folder inside it. SwiftBar does not load hidden folders, so the wrapped plugins stay out of the menu bar and you switch nothing off by hand. `claude-agents.15s.rb` goes next to quietbar as a second menu bar item, since it is not part of the wrapper; `--no-agents` leaves it out.
- Makes the scripts executable.
- Writes `~/.config/quietbar/config.yml` and `~/.config/quietbar/presets.yml` if they don't exist.
- Downloads the Homebrew services plugin and patches it (see [Third-party code](#third-party-code)).
- Sets SwiftBar's plugin folder only when none is set. If SwiftBar already uses another folder, it says so and what to do (point SwiftBar at the target, or use `--target`).
- Never overwrites a file without `--force`. It lists the ones it kept.

Options: `--target DIR`, `--force`, `--no-fetch` (skip the download), `--no-prefs` (leave SwiftBar's preferences alone), `--no-agents` (skip the Claude agents item). To update, `git pull` and run `./install.sh --force`; your config and presets are never touched.

If the plugin folder already holds other plugins, they keep showing beside quietbar. The installer lists them. Move them out or switch them off in SwiftBar.

### Claude usage

Claude Code tells its status line how much of the plan is used. `claude-usage.py --statusline` is a status line that records it, and the Claude row reads that. Nothing calls an API and no login or token is read. Add this to `~/.claude/settings.json` (the installer prints the exact path, nothing is edited for you):

```json
"statusLine": { "type": "command", "command": "<plugin folder>/.quietbar/bin/claude-usage.py --statusline" }
```

Already have a status line? Call this script from yours and ignore its output. Until the first Claude response after that, the row says "no reading" and its menu says what to do. The cache is `~/.cache/claude-usage/usage.json`.

## Claude agents

A menu bar item of its own, `claude-agents.15s.rb` (SwiftBar takes the 15 second refresh from the file name). It shows the number of Claude Code instances that are working right now, or `0` in grey. The dropdown has one group per Claude profile, with one row per open session and its running sub-agents indented below:

```
sparkles 2
---
2 active · 3 open · 2 interactive · 1 headless · 1 sub-agents
---
Default · ~/.claude · 2 running
api-refactor  ·  ~/code/api  ·  interactive  ·  opus 5.5  ·  138k ctx  ·  busy  ·  1h12m
  Explore  ·  sonnet 5.5  ·  41k ctx  ·  Find the retry logic  ·  4m
Work · ~/.claude-work · 0 running
None running
```

Clicking a session focuses its terminal tab. Clicking a headless run (`claude -p`) or a sub-agent opens a read-only follower of its transcript in a new tab. Under "Recent headless" in each group, clicking a finished run resumes it in a new tab. Holding Option shows pid, tty and session id under each row.

**How profiles are found.** The plugin looks in your home folder for `~/.claude`, every `~/.claude-*` folder and the folder in `CLAUDE_CONFIG_DIR` if set, and keeps those that hold a `sessions/` or `projects/` folder. Each becomes one group, so a Mac with one Claude setup shows one group, and none shows "No Claude setups found". The label comes from the folder name: `.claude` is "Default", `.claude-work` is "Work", `.claude-my-work` is "My Work".

**What counts.** A session is a `sessions/<pid>.json` whose process is still alive and still a `claude` process. A sub-agent is running when its parent session is alive, its transcript was written within the freshness window and the parent transcript holds no finish notice for it. The plugin only reads; nothing in the profiles is changed. The context figure is the last message's token count. A percentage is added only for models whose name carries `[1m]` (a 1M window), because the transcripts don't record the window size.

**Terminal.** Clicks drive Terminal.app (the default) or iTerm2 with AppleScript; the first click makes macOS ask for permission to control it. For any other terminal, a click shows a notification saying so, since there is no portable way to focus or open a tab there. If a session runs inside tmux, its pane is selected whichever terminal you use.

Settings go in the `claude_agents` block of the quietbar config. All of it is optional and the values shown are the defaults:

```yaml
claude_agents:
  terminal: Terminal          # Terminal or iTerm2
  icon: sparkles              # SF Symbol
  colors:
    busy: '#2da44e,#4ade80'   # light,dark
    idle: '#8e8e93,#98989d'
  agent_fresh_minutes: 30     # a sub-agent counts as running only if written to this recently
  recent_hours: 2             # headless runs that ended within this window are listed
  recent_max: 8               # ... at most this many per profile
  profiles:
    exclude: [.claude-old]            # folder names or paths to leave out
    include: [~/work/claude-config]   # extra folders; used even without sessions/ or projects/
    names:                            # group labels, by folder name or path
      .claude: Personal
```

The plugin reads `QUIETBAR_CONFIG` or `~/.config/quietbar/config.yml`; the wrapper ignores this block. A config that doesn't parse is ignored, with a note at the bottom of the menu. `claude-agents.15s.rb profiles` prints the profiles it found, one per line.

## Settings

Settings live in `~/.config/quietbar/config.yml` (`QUIETBAR_CONFIG` points elsewhere). The plugins read a few more from their environment. Put them under `env:` in the config; they are passed to every plugin. For the `task` command, `bin/svc.sh` and the like on the command line, export them in your shell too.

| Setting | Default | Meaning |
| --- | --- | --- |
| `QUIETBAR_PROJECTS_DIR` | `~/git` | The folder git-status scans, ports opens its folder picker at, and macstat shortens paths with. |
| `QUIETBAR_LABEL_PREFIX` | `local.quietbar` | launchd labels that start with this are yours: tasks made with `task add` are `<prefix>.<name>`, and loadout and dev-processes list agents with this prefix. |
| `QUIETBAR_SIZE_PATHS` | npm, gradle, Xcode, Docker and other dev caches (those that exist) | mac-health: colon-separated folders whose size it reports. |
| `SUPERVISOR_CONF` | `<brew prefix>/etc/supervisord.conf` | Only used if you run supervisor. |
| `LOADOUT_FILE` | `~/.config/quietbar/presets.yml` | Presets file for Loadout. |
| `CLAUDE_USAGE_CACHE` | `~/.cache/claude-usage` | Where the Claude usage cache lives. |

Other files: tasks keep their logs in `~/Library/Logs/quietbar-tasks`; mac-health caches slow probes in `~/.cache/swiftbar-mac-health`.

To drop a row, delete its section in the config. To add one, add a section: any SwiftBar plugin works, see below. Git and Dev are in the config as commented-out sections.

## Third-party code

- The Homebrew services plugin is Jim Myhrberg's `xbar/brew-services.10m.rb` (v3.2.3, commit `83c7fb1`) from [jimeh/dotfiles](https://github.com/jimeh/dotfiles/tree/main/xbar). That repository has no licence file, so the plugin is not copied into this repo. `install.sh` downloads that exact commit, checks its checksum and applies `patches/brew-services.patch`. The patch makes Start All and Restart All skip hidden services (upstream's `brew services start --all` also starts those). The file header says so.
- Everything else here is original and MIT, see `LICENSE`. The plugins share one small menu helper, `lib/menu_kit.rb`, written for this repo.

## Why the plugins live in `.quietbar/`

SwiftBar 2.1.1 loads plugins from the plugin folder and from every folder below it. It skips files and folders whose name starts with a dot, and it reads an optional `.swiftbarignore` in the plugin folder. A hidden folder is the one way that works on every version, so the wrapped plugins go in `.quietbar/modules`. quietbar looks there by default (`dir` in the config changes that).

## Notes for plugin authors

SwiftBar 2.1.x updates an open menu in place. When a row with a submenu changes its text between refreshes ("Mac — 106 GB free" becomes "105 GB free"), it patches the row and drops its action: the row goes grey and its submenu won't open. quietbar gives every row with a submenu a `font` name made from the row's own text. No font has that name, so nothing changes visually, but a changed row now looks new and SwiftBar rebuilds it. Rows that set a font already are left alone.

## Config

The shipped `config.yml` wraps the bundled plugins. `docs/rules-examples.yml` shows every rule key on made-up plugins. To wrap your own plugins:

```yaml
dir: ~/SwiftBar/Plugins     # where relative paths start (default: .quietbar/modules next to quietbar)
timeout: 15                 # seconds before a plugin counts as "no answer"
icon: circle.grid.2x2       # SF Symbol for the menu bar
separator: ": "             # between section name and summary
env:                        # extra environment for every plugin (see Settings)
  QUIETBAR_PROJECTS_DIR: ~/code

sections:
  - name: Docker
    path: docker.1m.sh
    summary:
      - { title: '(\d+) running', text: '{1} running' }
    alerts:
      - { body: '^Unhealthy \((?<n>\d+)\)', level: critical, label: 'docker {n} unhealthy' }
```

Sections show in the order listed. A section needs `path`. `name` defaults to the file name.

| Section key | Meaning |
| --- | --- |
| `name`, `path` | Row name and the plugin to run. Relative paths start at `dir`. |
| `timeout` | Overrides the global timeout for this plugin. |
| `setup` | Text shown in the row's menu, with the row "not set up", when the plugin file isn't there yet. Without it a missing file shows `not found`. |
| `title_strip` | Regex removed from the title text first, for a leading glyph such as `\A●\s*`. |
| `summary` | Rules for the row text. The first rule that matches wins. |
| `alerts` | Rules for raising an alert. The first rule that fires wins. `false` turns alerts off. |
| `alert_suffix` | Template added to the row text whenever an alert fires. |

A rule is a set of conditions and, if it matches, some output.

| Rule key | Meaning |
| --- | --- |
| `title`, `body` | Regex, or a list of regexes that must all match. `title` is the plugin's first line without its parameters. `body` is everything after the first `---`. |
| `color` | `any`, `critical` or `warn`: the plugin's title colour must be one of these. |
| `level` | `critical` or `warn`. Fixes the level whatever the colour. Without it the level comes from the title colour. |
| `label` | Menu bar label. Default: the title text. |
| `text` | Replaces the row text. |
| `suffix` | Added to the row text. Overrides `alert_suffix`. |

Templates read `{title}`, `{label}`, named captures such as `{n}`, and numbered captures such as `{1}`. Two filters exist: `{n:round}` rounds to a whole number, and `{n:max}` takes the largest value of that capture across all matches in the text.

## The alert contract

A wrapped plugin needs to do nothing special. quietbar reads what any SwiftBar plugin already prints.

- A red title colour means critical. Orange, amber or yellow means warning. Other colours, and no colour, mean no alert. Colours given as `light,dark` pairs use the first value.
- The label is the title text, trimmed.
- With no `alerts` key in the config, the colour is the only signal. Add rules when a plugin signals trouble in some other way, such as a line in its menu, or when you want a different label or only one level to count.
- A plugin that exits with an error and prints no menu, or whose title starts with `:warning:`, gets an `error` row holding its output.
- A plugin that outlives its timeout is killed and gets a `no answer` row. A missing file shows `not found`, or the section's `setup` text.

## Notes

- Each wrapped plugin runs on every quietbar refresh. Its own refresh interval in the file name no longer matters.
- Plugins see `SWIFTBAR_PLUGIN_PATH` pointing at quietbar, so a menu item that refreshes its plugin refreshes the whole menu. Their data and cache folders stay where SwiftBar would have put them. A plugin's output on stderr is only shown when it crashes.
- Parameters on a plugin's title line, such as `dropdown=false`, are used for the summary and then dropped.

## License

MIT
