#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>quietbar</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.desc>One quiet menu bar icon that wraps other SwiftBar plugins. Text appears only when one of them signals a problem.</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>
# <xbar.var>string(QUIETBAR_CONFIG="~/.config/quietbar/config.yml"): Path to the YAML config.</xbar.var>
#
# Runs the plugins listed in the config in parallel, each as it is. Every one
# becomes a summary row with its own menu one level down. The menu bar shows
# an icon, plus the worst alert label (and "+N" for the rest) when something
# needs attention. See README.md for the config format and the alert contract.

require 'open3'
require 'yaml'

Encoding.default_external = Encoding::UTF_8
Thread.report_on_exception = false

SELF = File.expand_path(__FILE__)
CONFIG = File.expand_path(ENV['QUIETBAR_CONFIG'] || '~/.config/quietbar/config.yml')
SUPPORT = File.expand_path('~/Library/Application Support/SwiftBar/Plugins')
CACHE = File.expand_path('~/Library/Caches/com.ameba.SwiftBar/Plugins')
RED = '#d93a2f,#f87171'
AMBER = '#d98e04,#fbbf24'
MUTED = '#8e8e93,#98989d'

Context = Struct.new(:text, :body, :level) # level: nil, :warn or :crit

def die(*lines)
  puts '| sfimage=exclamationmark.triangle'
  puts '---'
  lines.each { |l| puts l }
  exit
end

# ---- colours ---------------------------------------------------------------

# Red is critical, orange and yellow are warnings, anything else is no signal.
def level_of(value)
  value = value.to_s.split(',').first.to_s.strip.downcase
  case value
  when 'red' then :crit
  when 'orange', 'yellow', 'amber' then :warn
  when /\A#(\h)(\h)(\h)\z/, /\A#(\h{2})(\h{2})(\h{2})\z/
    r, g, b = Regexp.last_match.captures.map { |h| (h * (3 - h.size)).hex / 255.0 }
    max = [r, g, b].max
    delta = max - [r, g, b].min
    return nil if delta < 0.35 * max

    hue = if max == r then 60 * (((g - b) / delta) % 6)
          elsif max == g then 60 * (((b - r) / delta) + 2)
          else 60 * (((r - g) / delta) + 4)
          end
    return :crit if hue < 20 || hue >= 340

    :warn if hue < 65
  end
end

# ---- rules -----------------------------------------------------------------

# A rule matches when every regex under `title` and `body` matches. Named
# captures become {name} in templates; unnamed ones become {1}, {2}, ...
# Returns [vars, scans] or nil.
def match_rule(rule, ctx)
  vars = { 'title' => ctx.text }
  scans = {}
  { 'title' => ctx.text, 'body' => ctx.body }.each do |key, subject|
    Array(rule[key]).each do |source|
      re = Regexp.new(source)
      m = re.match(subject) or return nil
      m.names.each { |n| scans[n] ||= [re, subject] }
      m.names.each { |n| vars[n] ||= m[n] }
      m.captures.each_with_index { |c, i| vars[(i + 1).to_s] ||= c }
    end
  end
  [vars, scans]
end

# {name}, {name:round} (nearest whole number), {name:max} (largest value of
# that named capture across every match in the text).
def fill(template, vars, scans)
  template.to_s.gsub(/\{(\w+)(?::(\w+))?\}/) do
    name = Regexp.last_match(1)
    filter = Regexp.last_match(2)
    value = vars[name].to_s
    case filter
    when 'round' then value.to_f.round.to_s
    when 'max'
      re, subject = scans[name]
      re ? subject.to_enum(:scan, re).map { Regexp.last_match[name].to_i }.max.to_s : value
    else value
    end
  end
end

def summarize(section, ctx)
  Array(section['summary']).each do |rule|
    vars, scans = match_rule(rule, ctx)
    return fill(rule['text'], vars, scans) if vars && rule['text']
  end
  ctx.text
end

LEVELS = { 'critical' => :crit, 'crit' => :crit, 'warn' => :warn, 'warning' => :warn }.freeze

# The first rule that fires wins. By default the only rule is "any title colour".
def alert_for(section, ctx)
  rules = section.key?('alerts') ? section['alerts'] : [{}]
  return nil unless rules && rules != 'off'

  Array(rules).each do |rule|
    level = LEVELS[rule['level'].to_s] || ctx.level
    next unless level
    next if rule['color'] && rule['color'] != 'any' && LEVELS[rule['color'].to_s] != ctx.level

    vars, scans = match_rule(rule, ctx)
    next unless vars

    label = rule.key?('label') ? fill(rule['label'], vars, scans) : ctx.text
    vars['label'] = label
    suffix = rule.key?('suffix') ? rule['suffix'] : section['alert_suffix']
    return { level: level, label: label,
             text: rule['text'] && fill(rule['text'], vars, scans),
             suffix: suffix && fill(suffix, vars, scans) }
  end
  nil
end

# ---- running plugins -------------------------------------------------------

# SwiftBar keeps per-plugin data and cache dirs named after the plugin's path.
# The wrapped plugin gets the dirs it would have had running on its own.
def child_env(path)
  base = lambda do |var, default|
    own = ENV[var].to_s
    own.end_with?(SELF) ? own.delete_suffix(SELF) : default
  end
  {
    'SWIFTBAR' => '1',
    'SWIFTBAR_PLUGIN_PATH' => SELF,
    'SWIFTBAR_PLUGIN_DATA_PATH' => File.join(base.call('SWIFTBAR_PLUGIN_DATA_PATH', SUPPORT), path),
    'SWIFTBAR_PLUGIN_CACHE_PATH' => File.join(base.call('SWIFTBAR_PLUGIN_CACHE_PATH', CACHE), path),
    'LANG' => 'en_US.UTF-8',
    'PATH' => [ENV['PATH'], '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']
              .compact.join(':')
  }
end

# [stdout lines, stderr lines, exited ok], or nil after the timeout. A plugin
# past its timeout is killed together with its child processes.
def run_plugin(path, timeout)
  out = err = ok = nil
  Open3.popen3(child_env(path), path, pgroup: true) do |stdin, stdout, stderr, wait|
    stdin.close
    readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
    unless wait.join(timeout)
      begin
        Process.kill('KILL', -wait.pid)
      rescue SystemCallError
        nil
      end
      return nil
    end
    out, err = readers.map(&:value)
    ok = wait.value.success?
  end
  lines = [out, err].map { |s| s.to_s.dup.force_encoding('UTF-8').scrub('?').lines.map(&:chomp) }
  [lines[0], lines[1], ok]
rescue SystemCallError, IOError
  nil
end

# ---- one section -> [rows, alert] ------------------------------------------

def collect(section, cfg)
  name = section['name'] || File.basename(section['path'].to_s, '.*')
  sep = cfg[:separator]
  muted = ->(word) { [["#{name}#{sep}#{word} | color=\"#{MUTED}\""], nil] }

  path = File.expand_path(section['path'].to_s, cfg[:dir])
  return muted.call('not found') unless File.file?(path)

  result = run_plugin(path, section['timeout'] || cfg[:timeout]) or return muted.call('no answer')
  lines, errors, ok = result
  split = lines.index { |l| l.strip == '---' }
  title = lines.first.to_s
  body = split ? lines[(split + 1)..-1] : []

  crashed = title.start_with?(':warning:') || (!ok && title.strip.empty?)
  if crashed
    detail = [body, errors, lines].find { |l| l.any? { |x| !x.strip.empty? } } || []
    return [["#{name}#{sep}error | color=\"#{AMBER}\"", *detail.reject { |l| l.strip.empty? }.map { |l| "--#{l}" }], nil]
  end
  return muted.call('no answer') if title.strip.empty?

  text, _, params = title.partition('|')
  text = text.strip
  text = text.sub(Regexp.new(section['title_strip']), '') if section['title_strip']
  color = params.match(/\bcolor=(?:"([^"]*)"|([^\s"]+))/)
  ctx = Context.new(text, body.join("\n"), level_of(color && (color[1] || color[2])))

  alert = alert_for(section, ctx)
  summary = (alert && alert[:text]) || summarize(section, ctx)
  summary += alert[:suffix].to_s if alert
  tint = alert ? " color=\"#{alert[:level] == :crit ? RED : AMBER}\"" : ''
  [["#{name}#{sep}#{summary} |#{tint}".sub(/ \|\z/, ''),
    *body.reject { |l| l.strip.empty? }.map { |l| "--#{l}" }],
   alert && [alert[:level], alert[:label]]]
rescue StandardError => e
  [["#{name}#{sep}config error | color=\"#{AMBER}\"", "--#{e.class}: #{e.message}"], nil]
end

# ---- main ------------------------------------------------------------------

begin
  config = YAML.safe_load(File.read(CONFIG)) || {}
rescue Errno::ENOENT
  die "No config found at #{CONFIG}.", 'Copy config.example.yml there, or set QUIETBAR_CONFIG.'
rescue Psych::SyntaxError, Psych::Exception => e
  die "Cannot read #{CONFIG}:", e.message
end

sections = Array(config['sections'])
die "No sections in #{CONFIG}." if sections.empty?

cfg = {
  dir: File.expand_path(config['dir'] || __dir__),
  timeout: config['timeout'] || 15,
  separator: config['separator'] || ': ',
  icon: config['icon'] || 'circle.grid.2x2'
}

results = sections.map { |s| Thread.new { collect(s, cfg) } }.map(&:value)
alerts = results.map(&:last).compact

worst = alerts.max_by.with_index { |(level, _), i| [level == :crit ? 1 : 0, -i] }
if worst
  more = alerts.size > 1 ? " +#{alerts.size - 1}" : ''
  tint = alerts.any? { |level, _| level == :crit } ? RED : AMBER
  puts "#{worst[1]}#{more} | sfimage=#{cfg[:icon]} sfcolor=\"#{tint}\" color=\"#{tint}\""
else
  puts "| sfimage=#{cfg[:icon]}"
end

puts '---'
results.each { |rows, _| rows.each { |row| puts row } }
puts '---'
puts 'Refresh | refresh=true'
