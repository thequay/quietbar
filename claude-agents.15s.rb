#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Claude agents</xbar.title>
# <xbar.version>v1.1.0</xbar.version>
# <xbar.desc>Counts running Claude Code instances (sessions, headless runs, sub-agents) across every Claude setup found on this Mac</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>
#
# Menu bar: an icon and the number of live instances. Dropdown: plan usage per
# profile, then one group per Claude profile with one row per session and its
# running sub-agents indented below. This is the AI half of the bar, its own
# menu bar item next to quietbar's Mac item; install.sh puts it next to
# quietbar.1m.rb.
#
# Profiles: every config folder in the home folder named .claude or .claude-*
# (plus the one in CLAUDE_CONFIG_DIR) that holds a sessions/ or projects/
# folder. A folder with neither is ignored, so a Mac with one Claude setup
# shows one group. Labels come from the folder name (.claude is "Default",
# .claude-work is "Work"). The `claude_agents` block of quietbar's config
# (~/.config/quietbar/config.yml, or QUIETBAR_CONFIG) renames, excludes or adds
# profiles and sets the terminal, icon, colours and time windows; see README.md.
#
# What counts, and how it is found (read-only, nothing in the profiles is
# changed):
# - Sessions: <profile>/sessions/<pid>.json, kept only if the pid is alive and
#   still a claude process. Headless `claude -p` runs register there too, with
#   entrypoint "sdk-cli" and no terminal; those are shown as headless. The file
#   goes away when the run ends.
# - Sub-agents: <profile>/projects/<proj>/<session>/subagents/agent-<id>.jsonl
#   plus its .meta.json (type, description). They live inside the parent
#   process, so they are judged from the files: running when the parent is
#   alive, the transcript was written within the freshness window (30 minutes
#   by default), and the parent transcript holds no task-notification for it
#   (or a foreground tool_result for it) newer than its last write.
# - Usage: 5-hour and weekly plan percentages with their reset times, read from
#   the cache bin/claude-usage.py writes when run as Claude Code's status line
#   (one reading per profile, see the README). Only that cache is read, never
#   an API, so the 15 second refresh costs nothing. A profile without a reading
#   (no status line set up, or an API-key setup that reports no limits) shows
#   "no usage data".
# - Context: last assistant message's input + cache read + cache creation
#   tokens. A percentage appears only when the model name carries "[1m]" (the
#   transcripts don't record the window).
#
# Clicks call this file again: `focus <pid>`, `follow <transcript> [pid]`,
# `resume <profile dir> <session id>`. `feed` is the read-only follower the
# follow click opens in a terminal tab. `profiles` lists the profiles found.
# Clicks drive Terminal.app or iTerm2 (the `terminal` setting) with
# AppleScript, so the first click makes macOS ask for Automation permission.
# With another terminal a click shows a notification instead; tmux panes are
# still selected.

require 'json'
require 'time'
require 'date'
require 'yaml'
require 'zlib'
require 'shellwords'
require 'open3'
require 'io/console'

Encoding.default_external = Encoding::UTF_8

# SwiftBar starts plugins with a minimal PATH. Homebrew (both prefixes) and
# MacPorts are where tmux usually lives.
ENV['PATH'] = [*ENV['PATH'].to_s.split(':'), '/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin',
               '/usr/bin', '/bin', '/usr/sbin', '/sbin'].reject(&:empty?).uniq.join(':')

HOME = Dir.home
SELF = File.expand_path(__FILE__)
CONFIG_FILE = File.expand_path(ENV['QUIETBAR_CONFIG'] || '~/.config/quietbar/config.yml')

# ---------- settings ----------

# The `claude_agents` block of the quietbar config. A missing file or block
# means defaults; a file that doesn't parse means defaults and a note in the menu.
def load_settings
  data = YAML.safe_load(File.read(CONFIG_FILE)) || {}
  block = data.is_a?(Hash) ? data['claude_agents'] : nil
  [block.is_a?(Hash) ? block : {}, nil]
rescue Errno::ENOENT
  [{}, nil]
rescue Psych::Exception, SystemCallError => e
  [{}, "#{File.basename(CONFIG_FILE)}: #{e.message.lines.first.to_s.strip}"]
end

SETTINGS, SETTINGS_ERROR = load_settings

def setting(*keys, default: nil)
  value = keys.reduce(SETTINGS) { |h, k| h.is_a?(Hash) ? h[k] : nil }
  value.nil? ? default : value
end

def positive(value, default)
  value.is_a?(Numeric) && value.positive? ? value : default
end

def words(value)
  Array(value).map(&:to_s).reject(&:empty?)
end

ICON = setting('icon', default: 'sparkles').to_s # SF Symbol
MUTED = setting('colors', 'idle', default: '#8e8e93,#98989d').to_s
GREEN = setting('colors', 'busy', default: '#2da44e,#4ade80').to_s
AMBER = setting('colors', 'warn', default: '#d98e04,#fbbf24').to_s
RED = setting('colors', 'critical', default: '#d93a2f,#f87171').to_s
TITLE_USAGE = setting('title', default: 'count').to_s == 'count_usage'
TERMINAL = setting('terminal', default: 'Terminal').to_s.strip

TAIL = 64 * 1024
HEAD = 128 * 1024
AGENT_FRESH = (positive(setting('agent_fresh_minutes'), 30) * 60).to_i
RECENT = (positive(setting('recent_hours'), 2) * 3600).to_i
RECENT_MAX = positive(setting('recent_max'), 8).to_i
AMBER_FROM = positive(setting('amber_from'), 60)
RED_FROM = positive(setting('red_from'), 85)
USAGE_CACHE = File.expand_path(setting('usage_cache') || ENV['CLAUDE_USAGE_CACHE'] || '~/.cache/claude-usage')
USAGE_STALE = 15 * 60

# ---------- profiles ----------

def expand(path)
  File.expand_path(path.to_s)
end

def real(path)
  File.realpath(path)
rescue SystemCallError
  path
end

def claude_dir?(dir)
  File.directory?("#{dir}/sessions") || File.directory?("#{dir}/projects")
end

# ".claude" -> "Default", ".claude-work" -> "Work", ".claude-my-work" -> "My Work"
def default_label(dir)
  base = File.basename(dir).sub(/\A\.+/, '')
  return 'Default' if base == 'claude'

  label = base.sub(/\Aclaude[-_]/, '').split(/[-_\s]+/).map(&:capitalize).join(' ')
  label.empty? ? base : label
end

# A config entry is a folder path, or a bare folder name such as ".claude-work".
def entry_matches?(entry, dir)
  entry = entry.to_s
  return File.basename(dir) == entry unless entry.include?('/') || entry.start_with?('~')

  real(expand(entry)) == real(dir)
end

def discover_profiles
  auto = [File.join(HOME, '.claude')] + Dir.glob('.claude-*', base: HOME).sort.map { |d| File.join(HOME, d) }
  env_dir = ENV['CLAUDE_CONFIG_DIR'].to_s
  auto << expand(env_dir) unless env_dir.empty?
  auto = auto.select { |d| claude_dir?(d) }
  added = words(setting('profiles', 'include')).map { |p| expand(p) }.select { |d| File.directory?(d) }
  excluded = words(setting('profiles', 'exclude'))
  names = setting('profiles', 'names', default: {})
  names = {} unless names.is_a?(Hash)

  seen = {}
  (auto + added).each_with_object([]) do |dir, list|
    key = real(dir)
    next if seen[key] || excluded.any? { |e| entry_matches?(e, dir) }

    seen[key] = true
    custom = names.find { |entry, _| entry_matches?(entry, dir) }
    label = custom ? custom[1].to_s : default_label(dir)
    list << [label.empty? ? default_label(dir) : label, dir]
  end
end

# ---------- reading ----------

def read_tail(path, bytes)
  File.open(path, 'rb') do |f|
    size = f.size
    f.seek([size - bytes, 0].max)
    data = f.read.to_s.force_encoding('UTF-8').scrub('?')
    size > bytes ? data.sub(/\A[^\n]*\n/, '') : data
  end
rescue SystemCallError
  ''
end

def read_head(path, bytes)
  File.open(path, 'rb') { |f| f.read(bytes).to_s.force_encoding('UTF-8').scrub('?') }
rescue SystemCallError
  ''
end

def parse(line)
  JSON.parse(line)
rescue JSON::ParserError
  nil
end

# [model, context tokens] from the newest assistant message with usage.
def last_usage(path)
  [TAIL, 1024 * 1024].each do |bytes|
    read_tail(path, bytes).lines.reverse_each do |l|
      next unless l.include?('"type":"assistant"') && l.include?('"usage"')

      d = parse(l) or next
      m = d['message'] or next
      u = m['usage'] or next
      next if m['model'].to_s.start_with?('<')

      ctx = u['input_tokens'].to_i + u['cache_read_input_tokens'].to_i + u['cache_creation_input_tokens'].to_i
      return [m['model'], ctx]
    end
  end
  [nil, nil]
end

def first_prompt(path)
  read_head(path, HEAD).lines.each do |l|
    next unless l.include?('"type":"user"')

    d = parse(l) or next
    next if d['isMeta']

    c = d.dig('message', 'content')
    c = c.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join(' ') if c.is_a?(Array)
    next unless c.is_a?(String)

    c = squeeze(c)
    return c unless c.empty? || c.start_with?('<')
  end
  nil
end

# ---------- formatting ----------

def squeeze(text)
  text.to_s.gsub(/\s+/, ' ').strip
end

def clip(text, max)
  text = squeeze(text)
  text.length > max ? "#{text[0, max - 1]}…" : text
end

def pretty_model(name)
  return '—' if name.nil? || name.empty?

  s = name.sub(/\[1m\]\z/, '').sub(/\Aclaude-/, '').sub(/-\d{8}\z/, '')
  case s
  when /\A([a-z]+)-(\d+)(?:-(\d+))?\z/ then "#{Regexp.last_match(1)} #{Regexp.last_match(2)}#{Regexp.last_match(3) ? ".#{Regexp.last_match(3)}" : ''}"
  when /\A(\d+)(?:-(\d+))?-([a-z]+)\z/ then "#{Regexp.last_match(3)} #{Regexp.last_match(1)}#{Regexp.last_match(2) ? ".#{Regexp.last_match(2)}" : ''}"
  else s
  end
end

def tokens(count)
  return '—' if count.nil?
  return "#{(count / 1_000_000.0).round(1)}M" if count >= 1_000_000
  return "#{(count / 1000.0).round}k" if count >= 10_000
  return "#{(count / 1000.0).round(1)}k" if count >= 1000

  count.to_s
end

def ctx_text(model, count, command = nil)
  text = tokens(count)
  return "#{text} ctx" unless count && (model.to_s.include?('[1m]') || command.to_s.include?('[1m]'))

  "#{text} ctx (#{(count * 100.0 / 1_000_000).round}%)"
end

def span(seconds)
  seconds = [seconds.to_i, 0].max
  return "#{seconds}s" if seconds < 60
  return "#{seconds / 60}m" if seconds < 3600

  h = seconds / 3600
  m = (seconds % 3600) / 60
  m.zero? ? "#{h}h" : "#{h}h#{m}m"
end

def short_path(path)
  path.to_s.sub(/\A#{Regexp.escape(HOME)}(?=\/|\z)/, '~')
end

def cell(text)
  text.to_s.tr('|', '¦').tr("\n", ' ')
end

# ---------- discovery ----------

def ps_rows(pids)
  return {} if pids.empty?

  out, = Open3.capture2e('ps', '-o', 'pid=,tty=,command=', '-p', pids.join(','))
  out.lines.each_with_object({}) do |l, h|
    pid, tty, cmd = l.strip.split(/\s+/, 3)
    h[pid.to_i] = { tty: tty, cmd: cmd.to_s } if pid.to_i.positive?
  end
end

def transcript_for(dir, sid)
  Dir.glob("#{dir}/projects/*/#{sid}.jsonl").first
end

# The parent transcript says whether a sub-agent has finished.
def agent_finished?(aid, tuid, mtime, parent_lines)
  note = parent_lines.select { |l| l.include?("<task-id>#{aid}</task-id>") }.last
  if note
    ts = note[/"timestamp":"([^"]+)"/, 1]
    stamp = begin
      ts && Time.parse(ts)
    rescue ArgumentError
      nil
    end
    return true if stamp.nil? || mtime <= stamp + 5
  end
  if tuid
    res = parent_lines.select { |l| l.include?("\"tool_use_id\":\"#{tuid}\"") && l.include?('tool_result') }.last
    return true if res && !res.include?('Async agent launched')
  end
  false
end

# Lines of the whole parent transcript that mention one of these sub-agents.
# A tail read is not enough: in a long session the finish notice can sit
# megabytes before the end of the file.
def parent_hits(transcript, files)
  needles = files.flat_map do |f|
    meta = begin
      JSON.parse(File.read(f.sub(/\.jsonl\z/, '.meta.json')))
    rescue SystemCallError, JSON::ParserError
      {}
    end
    ["<task-id>#{File.basename(f, '.jsonl').sub(/\Aagent-/, '')}</task-id>", meta['toolUseId'] && "\"tool_use_id\":\"#{meta['toolUseId']}\""]
  end.compact
  File.foreach(transcript, encoding: 'UTF-8').select do |l|
    l = l.scrub('?')
    needles.any? { |n| l.include?(n) }
  end
rescue SystemCallError
  []
end

def running_agents(transcript, sid, now)
  sdir = File.join(File.dirname(transcript), sid, 'subagents')
  files = Dir.glob("#{sdir}/agent-*.jsonl").select { |f| now - File.mtime(f) < AGENT_FRESH }
  return [] if files.empty?

  parent_lines = parent_hits(transcript, files)
  files.map do |f|
    aid = File.basename(f, '.jsonl').sub(/\Aagent-/, '')
    mtime = File.mtime(f)
    meta = begin
      JSON.parse(File.read(f.sub(/\.jsonl\z/, '.meta.json')))
    rescue SystemCallError, JSON::ParserError
      {}
    end
    next if agent_finished?(aid, meta['toolUseId'], mtime, parent_lines)

    model, ctx = last_usage(f)
    started = read_head(f, 8192)[/"timestamp":"([^"]+)"/, 1]
    started = begin
      started && Time.parse(started)
    rescue ArgumentError
      nil
    end
    { id: aid, path: f, type: meta['agentType'] || 'agent', desc: meta['description'], model: model || meta['model'],
      ctx: ctx, started: started || mtime }
  end.compact.sort_by { |a| a[:started] }
end

def live_sessions(name, dir, now)
  entries = Dir.glob("#{dir}/sessions/*.json").map do |f|
    d = parse(File.read(f))
    d if d.is_a?(Hash) && d['pid'] && d['sessionId']
  rescue SystemCallError
    nil
  end.compact
  procs = ps_rows(entries.map { |d| d['pid'] })
  entries.select { |d| procs[d['pid']] && procs[d['pid']][:cmd] =~ /claude/i }.map do |d|
    proc_info = procs[d['pid']]
    path = transcript_for(dir, d['sessionId'])
    model, ctx = path ? last_usage(path) : [nil, nil]
    headless = d['entrypoint'].to_s != 'cli' || proc_info[:tty] == '??'
    {
      profile: name, dir: dir, pid: d['pid'], sid: d['sessionId'], cwd: d['cwd'], name: d['name'],
      headless: headless, status: d['status'] || 'idle', tty: proc_info[:tty], cmd: proc_info[:cmd],
      started: Time.at(d['startedAt'].to_i / 1000.0), path: path, model: model, ctx: ctx,
      task: path ? first_prompt(path) : nil,
      agents: path ? running_agents(path, d['sessionId'], now) : []
    }
  end.sort_by { |s| [s[:headless] ? 1 : 0, s[:started]] }
end

def recent_headless(name, dir, live_ids, now)
  Dir.glob("#{dir}/projects/*/*.jsonl").map { |f| [f, File.mtime(f)] }
     .select { |f, t| now - t < RECENT && !live_ids.include?(File.basename(f, '.jsonl')) }
     .sort_by { |_, t| -t.to_f }.map do |f, t|
    head = read_head(f, HEAD)
    next unless head =~ /"entrypoint":"sdk/

    model, ctx = last_usage(f)
    { profile: name, dir: dir, sid: File.basename(f, '.jsonl'), cwd: head[/"cwd":"([^"]+)"/, 1], ended: t,
      model: model, ctx: ctx, task: first_prompt(f) }
  end.compact.first(RECENT_MAX)
end

# ---------- usage ----------

USAGE_WINDOWS = [['five_hour', '5-hour'], ['seven_day', 'week']].freeze
WEEK = 7 * 24 * 3600

# The readings bin/claude-usage.py recorded, by the realpath of their profile
# folder. A reading without a recorded folder is the default profile's.
def usage_readings
  files = [File.join(USAGE_CACHE, 'usage.json')] + Dir.glob(File.join(USAGE_CACHE, 'profiles', '*', 'usage.json')).sort
  files.each_with_object({}) do |f, readings|
    data = parse(File.read(f))
    readings[real(data['config_dir'] || File.join(HOME, '.claude'))] = data if data.is_a?(Hash)
  rescue SystemCallError
    next
  end
end

# [percent used, reset time or nil] for one window; nil when it isn't recorded.
# Once the reset time has passed nothing has been used in the new window yet.
def usage_window(data, key, now)
  w = data[key]
  return nil unless w.is_a?(Hash) && w['used'].is_a?(Numeric) && w['resets_at'].is_a?(Numeric)
  return [0.0, nil] if w['resets_at'] <= now.to_i

  [w['used'].to_f, Time.at(w['resets_at'])]
end

def usage_tint(pct)
  return RED if pct >= RED_FROM
  return AMBER if pct >= AMBER_FROM

  GREEN
end

def left(seconds)
  seconds = [seconds.to_i, 0].max
  return "#{seconds / 86_400}d #{seconds % 86_400 / 3600}h" if seconds >= 86_400
  return format('%dh %02dm', seconds / 3600, seconds % 3600 / 60) if seconds >= 3600

  "#{seconds / 60}m"
end

def reset_text(at, now)
  clock = at.strftime(at.to_date == now.to_date ? '%H:%M' : '%a %H:%M')
  "resets #{clock} (in #{left(at - now)})"
end

def usage_rows(label, data, now)
  windows = data ? USAGE_WINDOWS.map { |key, name| [key, name, usage_window(data, key, now)] }.reject { |*, w| w.nil? } : []
  if windows.empty?
    return ["#{cell(label)}  ·  no usage data (an API-key setup, or the status line isn't set up) | sfimage=gauge color=\"#{MUTED}\"",
            "#{cell(label)}  ·  see \"Claude agents\" in the quietbar README | alternate=true color=\"#{MUTED}\""]
  end
  windows.map do |key, name, (pct, at)|
    parts = [cell(label), "#{name} #{pct.round}%", at ? reset_text(at, now) : 'reset, nothing used since']
    parts << "#{(100.0 * (now - (at - WEEK)) / WEEK).clamp(0, 100).round}% of week gone" if key == 'seven_day' && at
    age = now.to_i - data['seen_at'].to_i
    parts << "as of #{span(age)} ago" if key == 'five_hour' && data['seen_at'] && age > USAGE_STALE
    "#{parts.join('  ·  ')} | sfimage=gauge sfcolor=\"#{usage_tint(pct)}\""
  end
end

# The highest 5-hour percentage across the profiles that have a reading.
def top_five_hour(groups, readings, now)
  groups.map { |_, dir, _, _| readings[real(dir)] }.compact
        .map { |data| usage_window(data, 'five_hour', now) }.compact.map(&:first).max
end

# ---------- menu ----------

SEPARATOR = /\A(--)*---\z/.freeze

def depth(line)
  line[/\A(?:--)*/].size / 2
end

# SwiftBar 2.1.x greys out a submenu row whose text changed since the last
# refresh. A font name derived from the row's text makes it look new, so it is
# rebuilt (same fix as mac.1m.rb).
def keep_submenus_live(lines)
  lines.each_with_index.map do |line, i|
    nxt = lines[i + 1]
    next line if line =~ SEPARATOR || nxt.nil? || nxt =~ SEPARATOR || depth(nxt) <= depth(line)

    params = line.split('|', 2)[1]
    next line if params.to_s =~ /(\A|\s)font=/

    tag = "font=\"row-#{format('%08x', Zlib.crc32(line))}\""
    params ? "#{line.rstrip} #{tag}" : "#{line.rstrip} | #{tag}"
  end
end

def action(*params)
  parts = ["bash=#{SELF}"]
  params.each_with_index { |p, i| parts << "param#{i + 1}=#{p}" }
  (parts + ['terminal=false']).join(' ')
end

def session_rows(s, now)
  busy = s[:status].to_s == 'busy'
  label = s[:headless] ? (s[:task] || s[:name]) : (s[:name] || s[:task] || "pid #{s[:pid]}")
  parts = [clip(label, 46), short_path(s[:cwd]), s[:headless] ? 'headless' : 'interactive',
           pretty_model(s[:model]), ctx_text(s[:model], s[:ctx], s[:cmd]), s[:status], span(now - s[:started])]
  click = if s[:headless]
            s[:path] ? action('follow', s[:path], s[:pid]) : nil
          else
            action('focus', s[:pid])
          end
  icon = s[:headless] ? 'bolt.fill' : 'terminal'
  color = busy ? GREEN : MUTED
  row = "#{cell(parts.join('  ·  '))} | sfimage=#{icon} sfcolor=\"#{color}\""
  row += " #{click}" if click
  detail = ["pid #{s[:pid]}", s[:tty] == '??' ? 'no tty' : s[:tty], "session #{s[:sid][0, 8]}", s[:cwd]]
  detail << "task: #{clip(s[:task], 80)}" if s[:task] && !s[:headless]
  rows = [row, "#{cell(detail.compact.join('  ·  '))} | alternate=true color=\"#{MUTED}\""]
  s[:agents].each do |a|
    ap = [a[:type], pretty_model(a[:model]), ctx_text(a[:model], a[:ctx]), clip(a[:desc] || 'no description', 50),
          span(now - a[:started])]
    rows << "#{cell("\u2003\u2003#{ap.join('  ·  ')}")} | sfimage=arrow.turn.down.right sfcolor=\"#{GREEN}\" " \
            "#{action('follow', a[:path], 0)}"
  end
  rows
end

def recent_row(r, now)
  parts = [clip(r[:task] || r[:sid][0, 8], 46), short_path(r[:cwd]), pretty_model(r[:model]),
           ctx_text(r[:model], r[:ctx]), "ended #{span(now - r[:ended])} ago"]
  "--#{cell(parts.join('  ·  '))} | sfimage=arrow.counterclockwise #{action('resume', r[:dir], r[:sid])}"
end

def render
  now = Time.now
  groups = discover_profiles.map do |name, dir|
    sessions = live_sessions(name, dir, now)
    recent = recent_headless(name, dir, sessions.map { |s| s[:sid] }, now)
    [name, dir, sessions, recent]
  end
  return render_empty if groups.empty?

  total = groups.sum { |_, _, ss, _| ss.sum { |s| 1 + s[:agents].size } }
  active = groups.sum { |_, _, ss, _| ss.sum { |s| (s[:status].to_s == 'idle' ? 0 : 1) + s[:agents].size } }
  readings = usage_readings
  puts bar_title(active, TITLE_USAGE ? top_five_hour(groups, readings, now) : nil)
  puts '---'

  nsess = groups.sum { |g| g[2].count { |s| !s[:headless] } }
  nhead = groups.sum { |g| g[2].count { |s| s[:headless] } }
  nagent = groups.sum { |g| g[2].sum { |s| s[:agents].size } }
  puts "#{active} active · #{total} open · #{nsess} interactive · #{nhead} headless · #{nagent} sub-agents | color=\"#{MUTED}\""

  lines = ['---', "Plan usage | color=\"#{MUTED}\""]
  groups.each { |name, dir, _, _| lines.concat(usage_rows(name, readings[real(dir)], now)) }
  groups.each do |name, dir, sessions, recent|
    lines << '---'
    count = sessions.sum { |s| 1 + s[:agents].size }
    lines << "#{cell(name)} · #{short_path(dir)} · #{count} running | color=\"#{MUTED}\""
    lines << "None running | color=\"#{MUTED}\"" if sessions.empty?
    sessions.each { |s| lines.concat(session_rows(s, now)) }
    next if recent.empty?

    lines << "Recent headless (#{recent.size}) | sfimage=clock color=\"#{MUTED}\""
    recent.each { |r| lines << recent_row(r, now) }
  end
  keep_submenus_live(lines).each { |l| puts l }
  footer
end

def bar_title(active, top)
  return "#{active} · #{top.round}% | sfimage=#{ICON} color=\"#{usage_tint(top)}\" sfcolor=\"#{usage_tint(top)}\"" if top && top >= AMBER_FROM
  return "#{active} · #{top.round}% | sfimage=#{ICON}" if top
  return "0 | sfimage=#{ICON} sfcolor=\"#{MUTED}\"" if active.zero?

  "#{active} | sfimage=#{ICON}"
end

def settings_warning
  puts "Config not read, using defaults: #{cell(SETTINGS_ERROR)} | sfimage=exclamationmark.triangle color=\"#{MUTED}\"" if SETTINGS_ERROR
end

def footer
  settings_warning
  puts '---'
  puts 'Refresh | refresh=true'
end

def render_empty
  puts "0 | sfimage=#{ICON} sfcolor=\"#{MUTED}\""
  puts '---'
  puts "No Claude setups found | color=\"#{MUTED}\""
  puts "Looks in ~/.claude and ~/.claude-* for a sessions or projects folder | color=\"#{MUTED}\""
  puts "Add other folders under claude_agents.profiles.include in #{short_path(CONFIG_FILE)} | color=\"#{MUTED}\""
  footer
end

# ---------- click actions ----------

class ScriptFailed < StandardError; end

def osascript(source)
  out, status = Open3.capture2e('osascript', '-e', source)
  [out.strip, status.success?]
end

def applescript(source)
  out, ok = osascript(source)
  raise ScriptFailed, out unless ok

  out
end

def as_quote(text)
  "\"#{text.gsub('\\') { '\\\\' }.gsub('"', '\\"')}\""
end

def notify(message)
  osascript("display notification #{as_quote(message)} with title \"Claude agents\"")
end

# :terminal and :iterm have AppleScript support below; any other name is
# returned as written and gets a notification.
def terminal
  case TERMINAL.downcase
  when '', /\Aterminal(\.app)?\z/ then :terminal
  when /\Aiterm2?(\.app)?\z/ then :iterm
  else TERMINAL
  end
end

def unsupported_terminal(what)
  notify("Can't #{what} in #{TERMINAL}. Supported: Terminal, iTerm2. " \
         "Set claude_agents.terminal in #{short_path(CONFIG_FILE)}.")
end

ITERM = 'application id "com.googlecode.iterm2"'

def terminal_run(command, what)
  case terminal
  when :terminal
    applescript(<<~SCRIPT)
      tell application "Terminal"
        activate
        do script #{as_quote(command)}
      end tell
    SCRIPT
  when :iterm
    applescript(<<~SCRIPT)
      tell #{ITERM}
        activate
        set w to (create window with default profile)
        tell current session of w to write text #{as_quote(command)}
      end tell
    SCRIPT
  else
    unsupported_terminal(what)
  end
end

def focus_tmux_pane(dev)
  fmt = "\#{pane_tty}\t\#{session_name}:\#{window_index}.\#{pane_index}\t\#{session_name}"
  out, status = Open3.capture2e('tmux', 'list-panes', '-a', '-F', fmt)
  return dev unless status.success?

  row = out.lines.map { |l| l.chomp.split("\t") }.find { |r| r[0] == dev }
  return dev unless row

  window = row[1].sub(/\.\d+\z/, '')
  system('tmux', 'select-window', '-t', window, out: File::NULL, err: File::NULL)
  system('tmux', 'select-pane', '-t', row[1], out: File::NULL, err: File::NULL)
  clients, = Open3.capture2e('tmux', 'list-clients', '-F', "\#{client_tty}\t\#{client_session}")
  client = clients.lines.map { |l| l.chomp.split("\t") }.find { |r| r[1] == row[2] }
  client ? client[0] : dev
rescue SystemCallError
  dev
end

def raise_terminal_tab(dev)
  case terminal
  when :terminal
    applescript(<<~SCRIPT)
      tell application "Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is #{as_quote(dev)} then
              set selected tab of w to t
              set miniaturized of w to false
              set index of w to 1
              activate
              return "ok"
            end if
          end repeat
        end repeat
        return "none"
      end tell
    SCRIPT
  when :iterm
    applescript(<<~SCRIPT)
      tell #{ITERM}
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if tty of s is #{as_quote(dev)} then
                select w
                select t
                select s
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
        return "none"
      end tell
    SCRIPT
  else
    :unsupported
  end
end

def focus(pid)
  tty, = Open3.capture2e('ps', '-o', 'tty=', '-p', pid.to_s)
  tty = tty.strip
  return notify("pid #{pid} is gone or has no terminal") unless tty.start_with?('tty')

  dev = focus_tmux_pane("/dev/#{tty}")
  case raise_terminal_tab(dev)
  when :unsupported then notify("Can't focus a window in #{TERMINAL}; the session is on #{dev}. Supported: Terminal, iTerm2.")
  when 'ok' then nil
  else notify("No #{terminal == :iterm ? 'iTerm2' : 'Terminal'} tab found for #{dev}")
  end
end

def follow(path, pid)
  terminal_run("clear; #{Shellwords.escape(SELF)} feed #{Shellwords.escape(path)} #{pid.to_i}", 'open a follower')
end

def resume(dir, sid)
  path = transcript_for(dir, sid)
  cwd = path && read_head(path, HEAD)[/"cwd":"([^"]+)"/, 1]
  cwd = HOME unless cwd && File.directory?(cwd)
  terminal_run("cd #{Shellwords.escape(cwd)} && CLAUDE_CONFIG_DIR=#{Shellwords.escape(dir)} " \
               "command claude --resume #{Shellwords.escape(sid)}", 'resume a session')
end

# ---------- read-only transcript follower ----------

def tool_hint(input)
  return '' unless input.is_a?(Hash)

  %w[command file_path path pattern url description query prompt].each do |k|
    return squeeze(input[k]) if input[k].is_a?(String) && !input[k].empty?
  end
  squeeze(input.values.find { |v| v.is_a?(String) }.to_s)
end

def feed_events(line)
  d = parse(line) or return []
  ts = d['timestamp'] && (Time.parse(d['timestamp']).localtime.strftime('%H:%M:%S') rescue nil)
  stamp = "\e[2m#{ts || '        '}\e[0m"
  c = d.dig('message', 'content')
  out = []
  case d['type']
  when 'user'
    c = c.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join(' ') if c.is_a?(Array)
    text = squeeze(c) if c.is_a?(String)
    out << [stamp, "\e[36mprompt\e[0m", text] if text && !text.empty? && !d['isMeta']
  when 'assistant'
    Array(c).each do |b|
      case b['type']
      when 'text' then out << [stamp, "\e[32mclaude\e[0m", squeeze(b['text'])] unless squeeze(b['text']).empty?
      when 'tool_use' then out << [stamp, "\e[33m#{b['name']}\e[0m", tool_hint(b['input'])]
      end
    end
  end
  out
end

def alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::EPERM
  true
rescue SystemCallError
  false
end

def feed(path, pid)
  $stdout.sync = true
  width = (IO.console&.winsize&.last rescue nil) || 120
  show = lambda do |events|
    events.each do |stamp, kind, text|
      visible = 9 + kind.gsub(/\e\[[\d;]*m/, '').length + 1
      puts "#{stamp} #{kind} #{clip(text, [width - visible - 1, 20].max)}"
    end
  end
  puts "\e[1mFollowing #{short_path(path)}\e[0m (read-only, Ctrl-C to stop)"
  size = File.size(path)
  history = read_tail(path, 512 * 1024).lines.flat_map { |l| feed_events(l) }
  show.call(history.last(15))
  pos = size
  buf = +''
  ended = 0
  loop do
    sleep 0.5
    now_size = begin
      File.size(path)
    rescue SystemCallError
      puts 'transcript gone'
      break
    end
    if now_size > pos
      data = File.open(path, 'rb') { |f| f.seek(pos); f.read(now_size - pos) }
      pos = now_size
      buf << data.force_encoding('UTF-8').scrub('?')
      while (i = buf.index("\n"))
        show.call(feed_events(buf.slice!(0..i)))
      end
      ended = 0
    elsif pid.positive? && !alive?(pid)
      ended += 1
      if ended > 2
        puts "\e[2m[run ended]\e[0m"
        break
      end
    end
  end
end

# ---------- main ----------

begin
  case ARGV[0]
  when 'focus' then focus(ARGV[1].to_i)
  when 'follow' then follow(ARGV[1], ARGV[2])
  when 'resume' then resume(ARGV[1], ARGV[2])
  when 'feed' then feed(ARGV[1], ARGV[2].to_i)
  when 'profiles' then discover_profiles.each { |name, dir| puts "#{name}\t#{dir}" }
  else render
  end
rescue ScriptFailed => e
  notify("#{TERMINAL}: #{e.message.lines.first.to_s.strip}")
end
