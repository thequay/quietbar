#!/bin/bash
# task-run.sh SLUG COMMAND: run COMMAND through bash for a task made by `task add`.
# Appends its output to ~/Library/Logs/quietbar-tasks/SLUG.log and records start, end and
# exit code in SLUG.status, which the tasks menu (modules/tasks.1m.rb) reads.
# Exits with the command's exit code so launchd's "last exit code" matches.

slug=$1 cmd=$2
[[ -n $slug && -n $cmd ]] || { echo "usage: task-run.sh SLUG COMMAND" >&2; exit 64; }

dir="$HOME/Library/Logs/quietbar-tasks"
log="$dir/$slug.log" status="$dir/$slug.status"
mkdir -p "$dir"

# Keep the log from growing for ever: past 1 MB, keep the last 200 KB.
if [[ -f $log && $(stat -f %z "$log") -gt 1000000 ]]; then
  tail -c 200000 "$log" > "$log.tmp" && mv -f "$log.tmp" "$log"
fi

write_status() { # start end exit
  printf 'start=%s\nend=%s\nexit=%s\n' "$1" "$2" "$3" > "$status.tmp" && mv -f "$status.tmp" "$status"
}

start=$(date +%s)
write_status "$start" "" ""
trap 'write_status "$start" "$(date +%s)" 143; exit 143' TERM

printf '\n=== %s start ===\n' "$(date '+%F %T')" >> "$log"
/bin/bash -c "$cmd" 2>&1 | tee -a "$log"
code=${PIPESTATUS[0]}
printf '=== %s end, exit %s ===\n' "$(date '+%F %T')" "$code" >> "$log"

write_status "$start" "$(date +%s)" "$code"
exit "$code"
