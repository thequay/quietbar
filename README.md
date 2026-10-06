# quietbar

Two quiet SwiftBar menu bar items: Mac for the state of your machine, AI for Claude Code.

**Mac** is the quietbar wrapper: disk, memory, services, ports, scheduled tasks and app presets each become one summary row, with their full menu one level down. The menu bar shows only an icon while everything is fine. When something needs attention, a short label appears next to the icon.

**AI** is its own plugin, `claude-agents.15s.rb`: how many Claude Code instances are running, and Claude plan usage, per Claude profile. See [Claude agents](#claude-agents).

This repo is the whole setup: the wrapper (`quietbar.1m.rb`), the plugins it wraps, the separate AI plugin (`claude-agents.15s.rb`), the helper scripts they call, a ready-made config and an installer. The wrapper also works on its own, with any SwiftBar plugins, without changing them. See [Config](#config).

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
| AI (`claude-agents.15s.rb`), its own menu bar item | Running Claude Code instances and plan usage (5-hour and weekly) per Claude profile. See [Claude agents](#claude-agents). | python3 and one setting in Claude Code, for usage |
| Git (`git-status`), off by default | Dirty, unpushed and stashed repos under your projects folder. | git |
| Dev (`dev-processes`), off by default | Running dev processes (node first) and launchd jobs, with a stop button. | |

The shared menu helper is `lib/menu_kit.rb`. Helper scripts in `bin/`: `svc.sh` (list and control Homebrew and supervisor services), `macstat.py` (memory and CPU per app), `claude-usage.py` (records Claude plan usage for the AI item), `task`, `task-run.sh` and `trash-rm.sh` (used by Tasks).

## Install

You need macOS, [SwiftBar](https://swiftbar.app) and Ruby 2.6 or newer (the one macOS ships works; nothing outside the standard library is used). The Mac row and the Claude usage recorder also need the Command Line Tools (`xcode-select --install`), Services needs [Homebrew](https://brew.sh). `install.sh` checks and tells you what is missing. It installs nothing itself.

Get the repo (clone it, or download the zip from GitHub), then run the installer from inside it:

```sh
cd quietbar
./install.sh
```

What it does:

- Copies `quietbar.1m.rb` into SwiftBar's current plugin folder (or `~/SwiftBar/Plugins` if none is set) and everything it wraps into a hidden `.quietbar/` folder inside it. SwiftBar does not load hidden folders, so the wrapped plugins stay out of the menu bar and you switch nothing off by hand. `claude-agents.15s.rb` goes next to quietbar as the second menu bar item (AI), since it is not part of the wrapper; `--no-agents` leaves it out.
- Makes the scripts executable.
- Writes `~/.config/quietbar/config.yml` and `~/.config/quietbar/presets.yml` if they don't exist.
- Downloads the Homebrew services plugin and patches it (see [Third-party code](#third-party-code)).
- Sets SwiftBar's plugin folder only when none is set. If SwiftBar already uses another folder, it says so and what to do (point SwiftBar at the target, or use `--target`).
- Never overwrites a file without `--force`. It lists the ones it kept.

Options: `--target DIR`, `--force`, `--no-fetch` (skip the download), `--no-prefs` (leave SwiftBar's preferences alone), `--no-agents` (skip the AI item). To update, `git pull` and run `./install.sh --force`; your config and presets are never touched.

If the plugin folder already holds other plugins, they keep showing beside quietbar. The installer lists them. Move them out or switch them off in SwiftBar.

## Claude agents

The AI item, `claude-agents.15s.rb` (SwiftBar takes the 15 second refresh from the file name). It shows the number of Claude Code instances that are working right now, or `0` in grey. With `title: count_usage` (see below) the highest 5-hour plan usage follows the count, as `3 · 7%`. The dropdown has one group per Claude profile, separated by lines. Each group starts with that profile's plan usage, drawn with the same bars as the Mac item, then has one row per open session with its running sub-agents indented below. Rows are monospace, so bars, numbers and columns line up:

```
sparkles 2          (title: count_usage shows "2 · 7%")
---
2 active · 3 open · 2 interactive · 1 headless · 1 sub-agents
---
Default  ·  ~/.claude  ·  3 running
5-hour ██░░░░░░░░░░░░░░░░░░    8%  resets 17:00 · in 4h 05m
Week   █████░░░░░░░░░░░░░░░   26%  resets Sun 10:00 · in 4d 21h
  time ██████░░░░░░░░░░░░░░   30%  on pace
idle  api-refactor                        opus 5.5    178k ctx         3h26m
busy  docs-pass                           sonnet 5.5  119k ctx           35m
        Explore: Find the retry logic     sonnet 5.5  72k ctx             2m
---
Work  ·  ~/.claude-work  ·  0 running
5-hour ░░░░░░░░░░░░░░░░░░░░     –  reset since · last seen 0% · 14h ago
Week   ██░░░░░░░░░░░░░░░░░░   12%  resets Fri 04:00 · in 2d 15h · as of 14h ago
  time ████████████░░░░░░░░   62%  up to 50 pts under pace
None running
```

The usage rows are the 5-hour and weekly windows, each with a bar, the percent used and when it resets. The `time` row under the week is how much of the week has gone, with a note comparing it to what you have used: "38 pts under pace" is capacity that is lost at the reset, "12 pts over pace" means the week is being used up early (the row turns amber), and within 5 points it says "on pace". Usage rows are green, amber from `amber_from` and red from `red_from`. A reading older than 15 minutes is grey and says "as of 14h ago" (its pace note says "up to" or "at least", since the use can only have grown). A window that has ended shows an empty bar and "reset since", with what it last said. A profile without a reading shows "Usage no data" in its group. In a session row, busy rows are in normal text with a green icon and idle rows are grey; the working folder, pid and session id are under each row while you hold Option.

Clicking a session focuses its terminal tab. Clicking a headless run (`claude -p`) or a sub-agent opens a read-only follower of its transcript in a new tab. Under "Recent headless" in each group, clicking a finished run resumes it in a new tab. Holding Option shows folder, pid, tty and session id under each row.

**How profiles are found.** The plugin looks in your home folder for `~/.claude`, every `~/.claude-*` folder and the folder in `CLAUDE_CONFIG_DIR` if set, and keeps those that hold a `sessions/` or `projects/` folder. Each becomes one group, so a Mac with one Claude setup shows one group, and none shows "No Claude setups found". The label comes from the folder name: `.claude` is "Default", `.claude-work` is "Work", `.claude-my-work` is "My Work".

**What counts.** A session is a `sessions/<pid>.json` whose process is still alive and still a `claude` process. A sub-agent is running when its parent session is alive, its transcript was written within the freshness window and the parent transcript holds no finish notice for it. The plugin only reads; nothing in the profiles is changed. The context figure is the last message's token count. A percentage is added only for models whose name carries `[1m]` (a 1M window), because the transcripts don't record the window size.

**Plan usage.** Claude Code hands its status line the plan's 5-hour and weekly usage, and nothing else holds it: it is not in the session files or transcripts, and reading it from Anthropic's servers would need your login token, which quietbar never touches. So `bin/claude-usage.py --statusline` is a status line that records it, and the AI item reads that record. The numbers are as fresh as the last response in a Claude session, and the item only reads files, never an API. Add this to the `settings.json` of every profile you want usage for (the installer prints the path, nothing is edited for you):

```json
"statusLine": { "type": "command", "command": "<plugin folder>/.quietbar/bin/claude-usage.py --statusline" }
```

Already have a status line? Call this script from yours and ignore its output. Each profile gets its own reading, since each can be a different account: the script takes the profile from the session's transcript folder (else `CLAUDE_CONFIG_DIR`, else `~/.claude`) and writes `~/.cache/claude-usage/usage.json` for `~/.claude` and `~/.cache/claude-usage-<name>/usage.json` for the others, where `<name>` is the folder name without the leading `.` and `claude-` (`~/.claude-work` is `work`), plus an `account.json` there with the profile folder. `CLAUDE_USAGE_CACHE` changes the prefix `~/.cache/claude-usage`. This is the layout of the author's own, larger usage tool, so the two can share one cache. The AI item finds a profile's reading by that name, or by the `account.json` of any `<prefix>-*` folder that names the profile, so an odd folder name still works. A profile with no reading, such as one that has no status line set up, or an API-key setup, which reports no plan limits, shows "no usage data". A status line only records while a session in that profile is open, so an old reading is normal: rows older than 15 minutes say "as of 14h ago", a window whose reset time has passed shows an empty bar and "reset since · last seen 0% · 14h ago" instead of its old percentage, and `title: count_usage` leaves out readings older than 15 minutes. Rows turn amber from 60% and red from 85%. Run `claude-usage.py` without arguments to see the readings.

**Terminal.** Clicks drive Terminal.app (the default) or iTerm2 with AppleScript; the first click makes macOS ask for permission to control it. For any other terminal, a click shows a notification saying so, since there is no portable way to focus or open a tab there. If a session runs inside tmux, its pane is selected whichever terminal you use.

Settings go in the `claude_agents` block of the quietbar config. All of it is optional and the values shown are the defaults:

```yaml
claude_agents:
  title: count                # count, or count_usage: count plus the highest 5-hour usage, "3 · 7%"
  terminal: Terminal          # Terminal or iTerm2
  icon: sparkles              # SF Symbol
  colors:                     # light,dark
    busy: '#2da44e,#4ade80'
    idle: '#8e8e93,#98989d'
    warn: '#d98e04,#fbbf24'
    critical: '#d93a2f,#f87171'
  amber_from: 60              # plan usage % where amber starts
  red_from: 85                # ... and red
  usage_cache: ~/.cache/claude-usage   # prefix of the usage cache: this folder for ~/.claude, <prefix>-<name> for the others. Set CLAUDE_USAGE_CACHE to match if you move it
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

### Moving from the old layout

Claude plan usage used to be a row in the Mac item. It now lives in the AI item, so quietbar has no Claude section any more. After `git pull` and `./install.sh --force`:

- Delete the `- name: Claude` section (`path: claude-usage.1m.rb`) from your `~/.config/quietbar/config.yml`, and `.quietbar/modules/claude-usage.1m.rb` from the plugin folder. Your config is never touched by the installer.
- The status line setting stays as it is, with one difference: it now records one reading per profile. The reading of `~/.claude` stays at `~/.cache/claude-usage/usage.json`; other profiles show "no usage data" until their `settings.json` has the status line too.
- The AI item appears next to quietbar. Move or switch off an older Claude agents plugin if you had one, or you get two.

## Settings

Settings live in `~/.config/quietbar/config.yml` (`QUIETBAR_CONFIG` points elsewhere). The plugins read a few more from their environment. Put them under `env:` in the config; they are passed to every plugin. For the `task` command, `bin/svc.sh` and the like on the command line, export them in your shell too.

| Setting | Default | Meaning |
| --- | --- | --- |
| `QUIETBAR_PROJECTS_DIR` | `~/git` | The folder git-status scans, ports opens its folder picker at, and macstat shortens paths with. |
| `QUIETBAR_LABEL_PREFIX` | `local.quietbar` | launchd labels that start with this are yours: tasks made with `task add` are `<prefix>.<name>`, and loadout and dev-processes list agents with this prefix. |
| `QUIETBAR_SIZE_PATHS` | npm, gradle, Xcode, Docker and other dev caches (those that exist) | mac-health: colon-separated folders whose size it reports. |
| `SUPERVISOR_CONF` | `<brew prefix>/etc/supervisord.conf` | Only used if you run supervisor. |
| `LOADOUT_FILE` | `~/.config/quietbar/presets.yml` | Presets file for Loadout. |
| `CLAUDE_USAGE_CACHE` | `~/.cache/claude-usage` | Prefix of the folders where `claude-usage.py` records Claude usage (`<prefix>` for `~/.claude`, `<prefix>-<name>` for the others). It runs from Claude Code, so set this in the environment Claude Code starts with, and set `claude_agents.usage_cache` to the same folder. |

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
