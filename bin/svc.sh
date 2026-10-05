#!/bin/zsh
# svc: list, start, stop and restart dev services: Homebrew services and supervisor programs.
#   svc                              table of services, what runs them, and their status
#   svc start|stop|restart NAME...   NAME can be the start of a name: postgres finds postgresql@18
#   svc start|stop|restart all       everything in the table
# Homebrew: stop keeps a service off after a reboot; start turns it back on at login.
# Supervisor (optional, `brew install supervisor`; queue workers, mailpit): stop lasts until
# supervisor restarts; autostart= in <brew prefix>/etc/supervisor.d/*.ini decides what starts at
# login. Without supervisor installed only the Homebrew side shows.
# A program supervisor runs is left out of the Homebrew side (say mailpit), so svc never starts
# Homebrew's clashing second copy of it.
# After a change it refreshes the SwiftBar menu (quietbar, or the plugin that called it).

export LC_CTYPE=en_US.UTF-8
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
if [[ -n ${SUPERVISOR_CONF:-} ]]; then
  :
elif [[ -d /opt/homebrew ]]; then
  SUPERVISOR_CONF=/opt/homebrew/etc/supervisord.conf
else
  SUPERVISOR_CONF=/usr/local/etc/supervisord.conf
fi

usage() {
  print -r -- "usage: svc [list]
       svc start|stop|restart NAME [NAME ...]
       svc start|stop|restart all

NAME can be the start of a service name, e.g. postgres for postgresql@18."
}

# Fills parallel arrays names, runners (brew|supervisor) and states, one entry per service.
# supervisor_up is 1 when supervisord answers.
load_services() {
  names=() runners=() states=()
  supervisor_up=0

  local -A sup
  local out line group raw state
  out=$(supervisorctl -c $SUPERVISOR_CONF status 2>/dev/null)
  for line in ${(f)out}; do
    raw=${${(z)line}[2]}
    case $raw in
      RUNNING)                 state=started ;;
      STARTING)                state=starting ;;
      STOPPED|STOPPING|EXITED) state=stopped ;;
      BACKOFF|FATAL|UNKNOWN)   state="error ($raw)" ;;
      *) continue ;;
    esac
    supervisor_up=1
    group=${${(z)line}[1]%%:*}   # app:app_00 -> app
    [[ -z ${sup[$group]} || $state == error* ]] && sup[$group]=$state
  done
  if (( ! supervisor_up )); then
    for group in ${(f)"$(sed -n 's/^\[program:\(.*\)\]$/\1/p' $SUPERVISOR_CONF ${SUPERVISOR_CONF:h}/supervisor.d/*.ini(N) 2>/dev/null)"}; do
      sup[$group]="stopped (supervisor off)"
    done
  fi

  local name code
  while IFS=$'\t' read -r name state code; do
    (( ${+sup[$name]} )) && continue   # supervisor runs this one
    case $state in
      started|scheduled) state=started ;;
      none|stopped)      state=stopped ;;
      error)             state="error${code:+ (exit $code)}" ;;
    esac
    names+=$name runners+=brew states+=$state
  done < <(brew services list --json 2>/dev/null | /usr/bin/ruby -rjson -e 'JSON.parse(STDIN.read).each { |s| puts [s["name"], s["status"], s["exit_code"]].join("\t") }' 2>/dev/null)

  for group in ${(ko)sup}; do
    names+=$group runners+=supervisor states+=${sup[$group]}
  done
}

show_table() {
  load_services
  if (( ! $#names )); then
    print "No services found."
    return
  fi

  local w1=7 w2=6 w3=6 i
  for i in {1..$#names}; do
    (( ${#names[i]} > w1 ))       && w1=${#names[i]}
    (( ${#runners[i]} > w2 ))     && w2=${#runners[i]}
    (( ${#states[i]} + 2 > w3 ))  && w3=$(( ${#states[i]} + 2 ))
  done

  local green= yellow= dim= bold= reset=
  if [[ -t 1 ]]; then
    green=$'\e[32m' yellow=$'\e[33m' dim=$'\e[2m' bold=$'\e[1m' reset=$'\e[0m'
  fi

  local h1=${(l:w1+2::─:)} h2=${(l:w2+2::─:)} h3=${(l:w3+2::─:)}
  print -r -- "┌${h1}┬${h2}┬${h3}┐"
  printf "│ ${bold}%-*s${reset} │ ${bold}%-*s${reset} │ ${bold}%-*s${reset} │\n" $w1 SERVICE $w2 "RUN BY" $w3 STATUS
  print -r -- "├${h1}┼${h2}┼${h3}┤"

  local sym color started=0 stopped=0 errored=0
  for i in {1..$#names}; do
    (( i > 1 )) && [[ $runners[i] != $runners[i-1] ]] && print -r -- "├${h1}┼${h2}┼${h3}┤"
    case $states[i] in
      started)  sym=● color=$green;  (( started++ )) ;;
      starting) sym=◐ color=$green;  (( started++ )) ;;
      stopped*) sym=○ color=$dim;    (( stopped++ )) ;;
      error*)   sym=▲ color=$yellow; (( errored++ )) ;;
      *)        sym=? color= ;;
    esac
    printf "│ %-*s │ ${dim}%-*s${reset} │ ${color}%s %-*s${reset} │\n" \
      $w1 $names[i] $w2 $runners[i] $sym $(( w3 - 2 )) $states[i]
  done
  print -r -- "└${h1}┴${h2}┴${h3}┘"

  local -a summary
  (( started )) && summary+="$started started"
  (( stopped )) && summary+="$stopped stopped"
  (( errored )) && summary+="$errored error"
  print -r -- "  ${(j: · :)summary}"
}

# Prints the one service NAME refers to: an exact name, or the only name that starts with it.
resolve() {
  local want=$1
  shift
  local -a names=("$@")

  if (( ${names[(Ie)$want]} )); then
    print -r -- $want
    return
  fi

  local -a hits=(${(M)names:#${(b)want}*})
  case $#hits in
    1) print -r -- $hits[1] ;;
    0) print -u2 -r -- "svc: no service called '$want'. Services: ${(j:, :)names}"; return 1 ;;
    *) print -u2 -r -- "svc: '$want' matches ${(j:, :)hits}. Use more of the name."; return 1 ;;
  esac
}

run_action() {  # run_action ACTION INDEX
  if [[ $runners[$2] == supervisor ]]; then
    supervisorctl -c $SUPERVISOR_CONF $1 "$names[$2]:*"
  else
    brew services $1 $names[$2]
  fi
}

wait_for_supervisor() {
  local i
  for i in {1..20}; do
    supervisorctl -c $SUPERVISOR_CONF status >/dev/null 2>&1
    (( $? != 4 )) && return 0   # 4: supervisord isn't answering yet
    sleep 0.5
  done
  return 1
}

refresh_swiftbar() {
  # Under SwiftBar, SWIFTBAR_PLUGIN_PATH is the plugin to refresh (quietbar); by hand, assume quietbar.
  local name=${${SWIFTBAR_PLUGIN_PATH:t}%%.*}
  pgrep -xq SwiftBar && open -g "swiftbar://refreshplugin?name=${name:-quietbar}"
}

action=${1:-list}
case $action in
  list|ls|status)
    show_table
    ;;

  start|stop|restart)
    shift
    if (( ! $# )); then
      usage >&2
      exit 1
    fi

    load_services
    targets=()
    if [[ $# == 1 && $1 == all ]]; then
      targets=({1..$#names})
    else
      # Resolve every name before touching anything, so a typo changes nothing.
      for word in "$@"; do
        target=$(resolve $word $names) || exit 1
        targets+=${names[(ie)$target]}
      done
    fi

    brew_targets=() sup_targets=() supervisor_starting=0
    for i in $targets; do
      if [[ $runners[i] == supervisor ]]; then
        sup_targets+=$i
      else
        brew_targets+=$i
        [[ $names[i] == supervisor && $action != stop ]] && supervisor_starting=1
      fi
    done
    if (( $#sup_targets && ! supervisor_up )); then
      if [[ $action == stop ]]; then
        sup_targets=()   # already stopped with supervisor
      elif (( ! supervisor_starting )); then
        print -u2 -r -- "svc: supervisor isn't running. Start it first: svc start supervisor"
        exit 1
      fi
    fi
    # Starting or restarting supervisor also starts its autostart programs.
    (( supervisor_starting )) && [[ $action == restart ]] && sup_targets=()

    rc=0
    if [[ $action == stop ]]; then
      for i in $sup_targets $brew_targets; do run_action stop $i || rc=$?; done
    else
      for i in $brew_targets; do run_action $action $i || rc=$?; done
      if (( $#sup_targets )); then
        if (( supervisor_starting )) && ! wait_for_supervisor; then
          print -u2 -r -- "svc: supervisor didn't come up"
          exit 1
        fi
        for i in $sup_targets; do run_action $action $i || rc=$?; done
      fi
    fi

    refresh_swiftbar
    exit $rc
    ;;

  help|-h|--help)
    usage
    ;;

  *)
    usage >&2
    exit 1
    ;;
esac
