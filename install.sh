#!/bin/bash
# install.sh: install quietbar and its bundled plugins for SwiftBar.
#
#   ./install.sh [--target DIR] [--force] [--no-fetch] [--no-prefs]
#
# Puts quietbar.1m.rb in SwiftBar's plugin folder and everything it wraps in a
# hidden folder inside it (.quietbar/), which SwiftBar does not load, so only
# quietbar shows in the menu bar. Writes ~/.config/quietbar/config.yml and
# presets.yml if they don't exist. Never overwrites a file without --force.
# Installs nothing else: it checks what is needed and tells you what is missing.
#
#   --target DIR   plugin folder to install into. Default: SwiftBar's current
#                  plugin folder, else ~/SwiftBar/Plugins.
#   --force        replace files that already exist (the config and presets
#                  files in ~/.config/quietbar are only ever created, never replaced).
#   --no-fetch     don't download the Homebrew services plugin.
#   --no-prefs     don't read or set SwiftBar's plugin folder preference.

set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config_dir="${QUIETBAR_CONFIG_DIR:-$HOME/.config/quietbar}"
domain=com.ameba.SwiftBar

# The Homebrew services plugin is not bundled: its author has not given it a
# licence. It is downloaded from this exact commit and patched here instead.
upstream_commit=83c7fb10a2ab91f59e5f0b46bc887cac372accc3
upstream_url="https://raw.githubusercontent.com/jimeh/dotfiles/$upstream_commit/xbar/brew-services.10m.rb"
upstream_sha256=99ac66142af9d4b52b2af9f2a2d3045c7c7305f4a8e1c96effa27bd79d49e99f

target= force=0 fetch=1 prefs=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --target) target=${2:-}; shift 2 || { echo "--target needs a folder" >&2; exit 64; } ;;
    --target=*) target=${1#--target=}; shift ;;
    --force) force=1; shift ;;
    --no-fetch) fetch=0; shift ;;
    --no-prefs) prefs=0; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $1 (try --help)" >&2; exit 64 ;;
  esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
missing=()

# ---- what is needed --------------------------------------------------------

say "Checking what quietbar needs"
if [[ -x /usr/bin/ruby ]]; then
  say "  ruby      ok ($(/usr/bin/ruby -e 'print RUBY_VERSION'))"
else
  missing+=("ruby: /usr/bin/ruby is missing; quietbar and every plugin are Ruby")
fi
# The plugins call /usr/bin/python3, which on a Mac without the Command Line Tools is only a stub.
if /usr/bin/xcode-select -p >/dev/null 2>&1 && [[ -x /usr/bin/python3 ]]; then
  say "  python3   ok (the Mac and Claude rows use it)"
else
  missing+=("python3: needs the Command Line Tools. Run 'xcode-select --install' for the Mac and Claude rows")
fi
if command -v brew >/dev/null 2>&1 || [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]]; then
  say "  brew      ok"
else
  missing+=("Homebrew: not found. The Services row needs it (https://brew.sh); the other rows work without")
fi
if [[ -d /Applications/SwiftBar.app || -d "$HOME/Applications/SwiftBar.app" ]]; then
  say "  SwiftBar  ok"
else
  missing+=("SwiftBar: not found in /Applications. Get it from https://swiftbar.app (or: brew install --cask swiftbar)")
fi

# ---- where to install ------------------------------------------------------

swiftbar_dir=
if [[ $prefs == 1 ]]; then
  swiftbar_dir=$(defaults read "$domain" PluginDirectory 2>/dev/null || true)
  swiftbar_dir=${swiftbar_dir/#\~/$HOME}
fi
if [[ -z $target ]]; then
  target=${swiftbar_dir:-$HOME/SwiftBar/Plugins}
fi
target=${target/#\~/$HOME}
say ""
say "Installing into $target"
mkdir -p "$target/.quietbar/modules" "$target/.quietbar/bin" "$target/.quietbar/lib" "$config_dir" || exit 1

# ---- copy ------------------------------------------------------------------

copied=0 kept=0
# put SRC DEST [MODE]: copy unless DEST exists and differs and --force isn't given
put() {
  local src=$1 dest=$2 mode=${3:-644}
  if [[ -e $dest ]]; then
    if cmp -s "$src" "$dest"; then chmod "$mode" "$dest"; return; fi
    if [[ $force != 1 ]]; then
      say "  kept      ${dest#$target/} (differs; --force replaces it)"
      kept=$((kept + 1))
      return
    fi
  fi
  cp "$src" "$dest" && chmod "$mode" "$dest" && copied=$((copied + 1))
}

put "$here/quietbar.1m.rb" "$target/quietbar.1m.rb" 755
for f in "$here"/modules/*.rb; do put "$f" "$target/.quietbar/modules/$(basename "$f")" 755; done
for f in "$here"/bin/*; do put "$f" "$target/.quietbar/bin/$(basename "$f")" 755; done
for f in "$here"/lib/*.rb; do put "$f" "$target/.quietbar/lib/$(basename "$f")" 644; done
put "$here/presets.example.yml" "$target/.quietbar/presets.example.yml" 644
put "$here/config.yml" "$target/.quietbar/config.example.yml" 644
say "  copied $copied file(s)"

# ---- the Homebrew services plugin ------------------------------------------

services="$target/.quietbar/modules/brew-services.1m.rb"
if [[ $fetch == 1 ]]; then
  if [[ -e $services && $force != 1 ]]; then
    say "  kept      .quietbar/modules/brew-services.1m.rb (--force fetches it again)"
  else
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/quietbar.XXXXXX")
    if curl -fsS --max-time 30 "$upstream_url" -o "$tmp/brew-services.rb" 2>"$tmp/err"; then
      if [[ $(shasum -a 256 "$tmp/brew-services.rb" | cut -d' ' -f1) != "$upstream_sha256" ]]; then
        warn "the downloaded Homebrew services plugin is not the expected file; not installing it"
      elif patch -s "$tmp/brew-services.rb" < "$here/patches/brew-services.patch"; then
        cp "$tmp/brew-services.rb" "$services" && chmod 755 "$services"
        say "  fetched   Homebrew services plugin (patched)"
      else
        warn "could not apply patches/brew-services.patch"
      fi
    else
      warn "could not download the Homebrew services plugin ($(head -n1 "$tmp/err")); the Services row will say so. Run install.sh again when online."
    fi
    rm -rf "$tmp"
  fi
fi

# ---- config and presets ----------------------------------------------------

create() { # SRC DEST: create only, never replace
  if [[ -e $2 ]]; then
    say "  kept      $2 (already there)"
  else
    cp "$1" "$2" && say "  created   $2"
  fi
}
create "$here/config.yml" "$config_dir/config.yml"
create "$here/presets.example.yml" "$config_dir/presets.yml"

# ---- SwiftBar --------------------------------------------------------------

say ""
others=()
for f in "$target"/*; do
  [[ -f $f && -x $f && $(basename "$f") != quietbar.1m.rb ]] && others+=("$(basename "$f")")
done
if [[ ${#others[@]} -gt 0 ]]; then
  say "SwiftBar also loads these files in $target, so they show up beside quietbar:"
  printf '  %s\n' "${others[@]}"
  say "Move them out, or switch them off in SwiftBar, if quietbar should be the only item."
  say ""
fi

if [[ $prefs == 1 ]]; then
  canon() { (cd "$1" 2>/dev/null && pwd -P) || echo "$1"; }
  if [[ -z $swiftbar_dir ]]; then
    if defaults write "$domain" PluginDirectory "$target" 2>/dev/null; then
      say "SwiftBar had no plugin folder; set it to $target. Restart SwiftBar to pick it up."
    else
      say "Set SwiftBar's plugin folder to $target (SwiftBar > Preferences > Plugin Folder)."
    fi
  elif [[ $(canon "$swiftbar_dir") == "$(canon "$target")" ]]; then
    say "SwiftBar already uses this folder. quietbar shows up within a minute (or choose Refresh All)."
  else
    say "SwiftBar uses $swiftbar_dir, not $target."
    say "Either point SwiftBar at $target (Preferences > Plugin Folder), or run: ./install.sh --target \"$swiftbar_dir\""
  fi
else
  say "Make sure SwiftBar's plugin folder is $target."
fi

# ---- what is still to do ---------------------------------------------------

say ""
say "Next"
say "  - Claude row: Claude Code has to tell quietbar its usage. Add this to ~/.claude/settings.json"
say "    (nothing is edited for you):"
say "      \"statusLine\": { \"type\": \"command\", \"command\": \"$target/.quietbar/bin/claude-usage.py --statusline\" }"
say "    Until then the row says \"no reading\" and its menu repeats these steps."
say "  - Settings live in $config_dir/config.yml (see README.md)."

if [[ ${#missing[@]} -gt 0 ]]; then
  say ""
  say "Missing, not installed by this script:"
  printf '  - %s\n' "${missing[@]}"
fi
