#!/bin/bash
# trash-rm.sh: rm-compatible front end to /usr/bin/trash (macOS 14 or newer), so deletes can be
# undone. The tasks menu uses it to remove task files. To make a shell's `rm` use it, alias or
# wrap `rm` to this script.

force=0 recursive=0 dirs=0 verbose=0
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; args+=("$@"); break ;;
    -?*)
      flags="${1#-}"
      for ((i = 0; i < ${#flags}; i++)); do
        case "${flags:i:1}" in
          f) force=1 ;;
          r|R) recursive=1 ;;
          d) dirs=1 ;;
          v) verbose=1 ;;
          i|I|P|W|x) ;;  # prompts and overwrite flags don't apply to the Trash
          *) echo "rm: illegal option -- ${flags:i:1}" >&2; exit 1 ;;
        esac
      done
      shift ;;
    *) args+=("$1"); shift ;;
  esac
done

if [[ ${#args[@]} -eq 0 ]]; then
  [[ $force -eq 1 ]] && exit 0
  echo "usage: rm [-f | -i] [-dIPRrvWx] file ..." >&2; exit 64
fi

status=0
targets=()
for t in "${args[@]}"; do
  base="${t%/}"; base="${base##*/}"
  if [[ "$t" == "/" || "$base" == "." || "$base" == ".." ]]; then
    echo "rm: \"$t\" may not be removed" >&2; status=1; continue
  fi
  if [[ ! -e "$t" && ! -L "$t" ]]; then
    [[ $force -eq 1 ]] || { echo "rm: $t: No such file or directory" >&2; status=1; }
    continue
  fi
  if [[ -d "$t" && ! -L "$t" && $recursive -eq 0 ]]; then
    if [[ $dirs -eq 0 ]] || [[ -n "$(ls -A "$t")" ]]; then
      echo "rm: $t: is a directory" >&2; status=1; continue
    fi
  fi
  targets+=("$t")
done

if [[ ${#targets[@]} -gt 0 ]]; then
  if /usr/bin/trash "${targets[@]}" 2>/dev/null; then
    [[ $verbose -eq 1 ]] && printf '%s\n' "${targets[@]}"
  else
    # Retry one by one so the error names the file that failed.
    for t in "${targets[@]}"; do
      if [[ -e "$t" || -L "$t" ]] && ! /usr/bin/trash "$t" 2>/dev/null; then
        echo "rm: $t: could not move to Trash" >&2; status=1
      elif [[ $verbose -eq 1 ]]; then
        echo "$t"
      fi
    done
  fi
fi
exit $status
