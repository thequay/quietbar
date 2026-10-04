# quietbar

One SwiftBar item that wraps your other SwiftBar plugins.

Each wrapped plugin becomes one summary row, with its full menu one level down. The menu bar shows only an icon while everything is fine. When a wrapped plugin reports a problem, a short label appears next to the icon.

quietbar runs the plugins as they are. You don't change them.

## What it looks like

All clear, the menu bar is just the icon:

```
[grid icon]
```

Docker has two unhealthy containers and the VPN is down:

```
[grid icon] docker 2 unhealthy +1
```

The dropdown has one row per plugin:

```
Disk: 82%
Docker: 5 running · 2 unhealthy
Deploys: error
VPN: down
Calendar: no answer
-------------------------------
Refresh
```

Pointing at a row opens that plugin's own menu. For Docker:

```
Docker: 5 running · 2 unhealthy  >  Containers
                                    Unhealthy (2):
                                      web
                                      worker
```

The label shows the worst alert. `+1` counts the others. The icon and label turn red if any alert is critical, otherwise amber.

## Install

1. Put `quietbar.1m.rb` in your SwiftBar plugin folder and make it executable (`chmod +x quietbar.1m.rb`). The `1m` in the name is how often it refreshes.
2. Copy `config.example.yml` to `~/.config/quietbar/config.yml` and list your plugins. Set `QUIETBAR_CONFIG` to use another path.
3. In SwiftBar, switch off the plugins quietbar now wraps. Leave their files where they are. quietbar runs them itself, and a plugin that stays on would show up twice.

Needs Ruby 2.6 or newer. The Ruby that ships with macOS works, and nothing outside the standard library is used.

## Config

```yaml
dir: ~/SwiftBar/Plugins     # where relative paths start (default: quietbar's own folder)
timeout: 15                 # seconds before a plugin counts as "no answer"
icon: circle.grid.2x2       # SF Symbol for the menu bar
separator: ": "             # between section name and summary

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
- A plugin that outlives its timeout is killed and gets a `no answer` row. A missing file shows `not found`.

## Notes

- Each wrapped plugin runs on every quietbar refresh. Its own refresh interval in the file name no longer matters.
- Plugins see `SWIFTBAR_PLUGIN_PATH` pointing at quietbar, so a menu item that refreshes its plugin refreshes the whole menu. Their data and cache folders stay where SwiftBar would have put them.
- Parameters on a plugin's title line, such as `dropdown=false`, are used for the summary and then dropped.

## License

MIT
