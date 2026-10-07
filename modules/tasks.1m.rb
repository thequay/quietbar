#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Tasks</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.desc>Scheduled tasks (launchd agents and cron): what runs when, what ran last, what is overdue or failed</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>
#
# Menu with no arguments, CLI with them (bin/task calls this file):
#   list | add | run NAME | enable NAME | disable NAME | rm NAME
# Tasks made with `add` are launchd agents labelled <QUIETBAR_LABEL_PREFIX>.<name>
# (default local.quietbar.<name>); their logs go to ~/Library/Logs/quietbar-tasks.

require 'cgi'
require 'date'
require 'fileutils'
require 'json'
require 'open3'

require_relative '../lib/menu_kit'

module Tasks
  class Error < StandardError; end
  class Cancelled < StandardError; end

  HOME = Dir.home
  DOMAIN = "gui/#{Process.uid}"
  AGENT_DIR = File.join(HOME, 'Library/LaunchAgents')
  LOG_DIR = File.join(HOME, 'Library/Logs/quietbar-tasks')
  STATE_FILE = File.join(LOG_DIR, '.state.json')
  WRAPPER = File.expand_path('../bin/task-run.sh', __dir__)
  TRASH = File.expand_path('../bin/trash-rm.sh', __dir__)
  LABEL_PREFIX = "#{ENV['QUIETBAR_LABEL_PREFIX'] || 'local.quietbar'}.".freeze
  # Handled by the brew-services plugin and svc.
  SKIP_PREFIXES = %w[sh.brew. homebrew.mxcl. com.apple.].freeze
  # PATH of a task run by launchd; folders that don't exist are left out.
  TASK_PATH = [
    '/opt/homebrew/bin', '/opt/homebrew/sbin', '/usr/local/bin',
    File.join(HOME, 'Library/Application Support/Herd/bin'),
    File.join(HOME, '.local/bin'), '/usr/bin', '/bin', '/usr/sbin', '/sbin'
  ].select { |dir| File.directory?(dir) }.join(':').freeze

  SOON = 3 * 3600
  # A run is only "missed" once it is this late, and not right after wake.
  GRACE = 90
  WAKE_GRACE = 120
  DAYS = %w[Sun Mon Tue Wed Thu Fri Sat].freeze
  MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
  DAY_NAMES = %w[sun mon tue wed thu fri sat].freeze

  Spec = Struct.new(:minute, :hour, :day, :month, :weekday)

  Task = Struct.new(
    :name, :label, :kind, :plist, :specs, :interval, :always, :at_load,
    :command, :outputs, :slug, :cron_expr, :schedule, :loaded, :disabled,
    :running, :pid, :runs, :exit_code, :status, :last_run, :last_src, :since,
    :seen_run, :next_run, :next_approx, :overdue, :failed, :result,
    keyword_init: true
  ) do
    def wrapped?
      !slug.nil?
    end

    def cron?
      kind == :cron
    end

    # Third-party jobs (Google updater, ...) are listed but never raise alarms.
    def own?
      cron? || label.start_with?(LABEL_PREFIX)
    end

    def log_path
      return File.join(LOG_DIR, "#{slug}.log") if wrapped?

      outputs.find { |f| File.exist?(f) } || outputs.first
    end
  end

  # ---------------------------------------------------------------------------
  # Schedules
  # ---------------------------------------------------------------------------

  module Schedule
    module_function

    def floor_minute(time)
      Time.at(time.to_i / 60 * 60)
    end

    def day_matches?(spec, date)
      return false if spec.month && !spec.month.include?(date.month)

      dom = spec.day ? spec.day.include?(date.day) : nil
      dow = spec.weekday ? spec.weekday.include?(date.wday) : nil
      return true if dom.nil? && dow.nil?
      return dow if dom.nil?
      return dom if dow.nil?

      dom || dow # cron: both restricted means either
    end

    def clock_times(spec)
      hours = spec.hour || (0..23).to_a
      minutes = spec.minute || (0..59).to_a
      hours.product(minutes)
    end

    # First match strictly after +from+.
    def next_after(spec, from)
      start = floor_minute(from) + 60
      date = Date.new(start.year, start.month, start.day)
      1500.times do
        if day_matches?(spec, date)
          clock_times(spec).each do |h, m|
            cand = Time.local(date.year, date.month, date.day, h, m)
            return cand if cand >= start
          end
        end
        date += 1
      end
      nil
    end

    # Last match strictly before +before+.
    def prev_before(spec, before)
      date = Date.new(before.year, before.month, before.day)
      1500.times do
        if day_matches?(spec, date)
          clock_times(spec).reverse_each do |h, m|
            cand = Time.local(date.year, date.month, date.day, h, m)
            return cand if cand < before
          end
        end
        date -= 1
      end
      nil
    end

    def next_of(specs, from)
      specs.map { |s| next_after(s, from) }.compact.min
    end

    def prev_of(specs, before)
      specs.map { |s| prev_before(s, before) }.compact.max
    end

    # launchd StartCalendarInterval: a dict or an array of dicts, missing keys are wildcards.
    def from_calendar(value)
      (value.is_a?(Hash) ? [value] : Array(value)).map do |d|
        Spec.new(*%w[Minute Hour Day Month Weekday].map { |k| d.key?(k) ? [d[k].to_i] : nil }).tap do |s|
          s.weekday = s.weekday.map { |w| w % 7 } if s.weekday
        end
      end
    end

    def parse_field(text, min, max, names = nil)
      return nil if text == '*'

      values = text.split(',').flat_map do |part|
        range, step = part.split('/', 2)
        step = step ? Integer(step) : 1
        raise Error, "bad cron field #{text}" if step < 1

        lo, hi = if range == '*' then [min, max]
                 elsif range.include?('-') then range.split('-', 2).map { |v| num(v, names) }
                 else
                   v = num(range, names)
                   step > 1 ? [v, max] : [v, v]
                 end
        raise Error, "bad cron field #{text}" if lo < min || hi > max || lo > hi

        (lo..hi).step(step).to_a
      end
      values.uniq.sort
    end

    def num(text, names)
      return names.index(text.downcase[0, 3]) if names && text =~ /\A[a-z]+\z/i

      Integer(text)
    end

    CRON_ALIASES = {
      '@hourly' => '0 * * * *', '@daily' => '0 0 * * *', '@midnight' => '0 0 * * *',
      '@weekly' => '0 0 * * 0', '@monthly' => '0 0 1 * *', '@yearly' => '0 0 1 1 *',
      '@annually' => '0 0 1 1 *'
    }.freeze

    def from_cron(fields)
      minute, hour, day, month, weekday = fields
      weekday = parse_field(weekday, 0, 7, DAY_NAMES)
      Spec.new(parse_field(minute, 0, 59), parse_field(hour, 0, 23), parse_field(day, 1, 31),
               parse_field(month, 1, 12, [''] + MONTHS),
               weekday && weekday.map { |w| w % 7 }.uniq.sort)
    end

    # Evenly spaced minutes starting at 0 (cron */15), or nil.
    def minute_step(minutes)
      return nil if minutes.size < 2 || minutes.first != 0

      step = minutes[1]
      return nil unless minutes == (0...60).step(step).to_a

      step
    end

    # [label, times] for the schedules this can name, nil otherwise.
    def shape(spec)
      return nil if spec.month

      if spec.hour.nil?
        return ['every minute', nil] if spec.minute.nil? && spec.day.nil? && spec.weekday.nil?
        return nil unless spec.minute && spec.day.nil? && spec.weekday.nil?

        step = minute_step(spec.minute)
        return ["every #{step} min", nil] if step
        return nil unless spec.minute.size == 1

        return ['hourly at', [format(':%02d', spec.minute.first)]]
      end
      return nil unless spec.minute

      times = clock_times(spec).map { |h, m| format('%02d:%02d', h, m) }
      return nil if times.size > 4

      if spec.day
        return nil if spec.weekday

        ["monthly day #{spec.day.join(',')}", times]
      elsif spec.weekday
        wd = spec.weekday
        label = if wd == [1, 2, 3, 4, 5] then 'weekdays'
                elsif wd == [0, 6] then 'weekends'
                elsif wd.size == 1 then "weekly #{DAYS[wd.first]}"
                else wd.map { |d| DAYS[d] }.join(',')
                end
        [label, times]
      else
        ['daily', times]
      end
    end

    # Specs that differ only in weekday (one dict per weekday) are one schedule.
    def merge_weekdays(specs)
      specs.group_by { |s| [s.minute, s.hour, s.day, s.month] }.map do |(minute, hour, day, month), group|
        days = group.map(&:weekday)
        Spec.new(minute, hour, day, month, days.any?(&:nil?) ? nil : days.flatten.uniq.sort)
      end
    end

    def describe(specs)
      shapes = merge_weekdays(specs).map { |s| shape(s) }
      return nil if shapes.empty? || shapes.any?(&:nil?)

      grouped = {}
      shapes.each { |label, times| (grouped[label] ||= []).concat(times || []) }
      grouped.map { |label, times| times.empty? ? label : "#{label} #{times.sort.uniq.join(', ')}" }.join('; ')
    end

    def interval_text(seconds)
      if seconds % 3600 == 0 then "every #{seconds / 3600} h"
      elsif seconds % 60 == 0 then "every #{seconds / 60} min"
      else "every #{seconds} s"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Formatting
  # ---------------------------------------------------------------------------

  module Fmt
    module_function

    def dur(seconds)
      seconds = seconds.to_i.abs
      days, rest = seconds.divmod(86_400)
      hours, rest = rest.divmod(3600)
      minutes = rest / 60
      return "#{days}d #{hours}h" if days.positive?
      return "#{hours}h #{minutes}m" if hours.positive?
      return "#{minutes}m" if minutes.positive?

      "#{seconds}s"
    end

    def stamp(time, now)
      days = (Date.new(time.year, time.month, time.day) - Date.new(now.year, now.month, now.day)).to_i
      day = case days
            when 0 then 'today'
            when 1 then 'tomorrow'
            when -1 then 'yesterday'
            when 2..6 then Tasks::DAYS[time.wday]
            else time.strftime('%a %-d %b')
            end
      "#{day} #{time.strftime('%H:%M')}"
    end

    def next_short(time, now)
      delta = time - now
      return 'now' if delta < 60
      return "in #{dur(delta)}" if delta < 6 * 3600

      stamp(time, now)
    end

    def next_long(time, now)
      "#{stamp(time, now)} (in #{dur(time - now)})"
    end

    def last_long(time, now)
      "#{stamp(time, now)} (#{dur(now - time)} ago)"
    end
  end

  # ---------------------------------------------------------------------------
  # Reading tasks
  # ---------------------------------------------------------------------------

  module Source
    module_function

    def run(*args)
      out, err, status = Open3.capture3(*args)
      [out, err, status.exitstatus]
    end

    def print_disabled
      out, _err, code = run('launchctl', 'print-disabled', DOMAIN)
      return {} unless code.zero?

      out.scan(/"([^"]+)"\s*=>\s*(true|false|disabled|enabled)/).to_h do |label, v|
        [label, %w[true disabled].include?(v)]
      end
    end

    def launchctl_info(label)
      out, _err, code = run('launchctl', 'print', "#{DOMAIN}/#{label}")
      return { loaded: false } unless code.zero?

      info = { loaded: true }
      info[:state] = out[/^\tstate = (\S+)/, 1]
      info[:runs] = out[/^\truns = (\d+)/, 1].to_i
      info[:pid] = out[/^\tpid = (\d+)/, 1]&.to_i
      exit_text = out[/^\tlast exit code = (.+)$/, 1]
      info[:exit] = exit_text =~ /\A-?\d+/ ? exit_text[/\A-?\d+/].to_i : nil
      info
    end

    def plist_json(path)
      out, _err, code = run('plutil', '-convert', 'json', '-o', '-', path)
      code.zero? ? JSON.parse(out) : nil
    rescue JSON::ParserError
      nil
    end

    def launchd_task(path, disabled)
      label = File.basename(path, '.plist')
      return if SKIP_PREFIXES.any? { |p| label.start_with?(p) }

      data = plist_json(path)
      return unless data

      specs = Schedule.from_calendar(data['StartCalendarInterval'])
      interval = data['StartInterval']
      scheduled = !specs.empty? || interval
      keep = data['KeepAlive'] ? true : false
      at_load = data['RunAtLoad'] ? true : false
      always = !scheduled && (keep || at_load)
      return unless scheduled || (always && label.start_with?(LABEL_PREFIX))

      args = Array(data['ProgramArguments'])
      args = [data['Program']] if args.empty? && data['Program']
      wrapped = args[1] == WRAPPER && args[2]
      slug = wrapped ? args[2] : nil
      command = wrapped ? args[3].to_s : args.join(' ')
      outputs = [data['StandardOutPath'], data['StandardErrorPath']].compact.uniq
      info = launchctl_info(label)
      schedule = if always then 'always on'
                 else
                   parts = []
                   parts << (Schedule.describe(specs) || 'calendar') unless specs.empty?
                   parts << Schedule.interval_text(interval) if interval
                   parts.join('; ')
                 end
      schedule += ' + at load' if scheduled && at_load

      Task.new(
        name: label.sub(/\A#{Regexp.escape(LABEL_PREFIX)}/, ''), label: label, kind: :launchd,
        plist: path, specs: specs, interval: interval, always: always, at_load: at_load,
        command: command, outputs: outputs, slug: slug, schedule: schedule,
        loaded: info[:loaded], disabled: disabled[label] ? true : false,
        running: info[:state] == 'running', pid: info[:pid], runs: info[:runs],
        exit_code: info[:exit]
      )
    end

    def launchd_tasks
      disabled = print_disabled
      Dir.glob(File.join(AGENT_DIR, '*.plist')).sort
         .map { |p| Thread.new { launchd_task(p, disabled) } }.map(&:value).compact
    end

    def cron_tasks
      out, _err, code = run('crontab', '-l')
      return [] unless code.zero?

      n = 0
      out.each_line.map do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#') || line =~ /\A[A-Za-z_][A-Za-z0-9_]*=/

        n += 1
        cron_task(line, n)
      end.compact
    end

    def cron_task(line, num)
      if line.start_with?('@')
        word, command = line.split(/\s+/, 2)
        fields = Schedule::CRON_ALIASES[word]&.split(' ')
        expr = word
        reboot = word == '@reboot'
        return unless command && (fields || reboot)
      else
        parts = line.split(/\s+/, 6)
        return if parts.size < 6

        fields = parts[0, 5]
        command = parts[5]
        expr = fields.join(' ')
      end
      specs = fields ? [Schedule.from_cron(fields)] : []
      schedule = reboot ? 'cron: at reboot' : (Schedule.describe(specs) || "cron: #{expr}")
      Task.new(
        name: "cron-#{num}", label: "cron-#{num}", kind: :cron, specs: specs, always: reboot,
        command: command, outputs: [], schedule: schedule, loaded: true, disabled: false,
        running: false, cron_expr: expr
      )
    rescue Error, ArgumentError
      Task.new(
        name: "cron-#{num}", label: "cron-#{num}", kind: :cron, specs: [], always: false,
        command: line, outputs: [], schedule: "cron: #{line.split(/\s+/, 6)[0, 5].join(' ')}",
        loaded: true, disabled: false, running: false
      )
    end

    def read_status(slug)
      file = File.join(LOG_DIR, "#{slug}.status")
      return unless File.file?(file)

      vals = File.read(file).each_line.map { |l| l.strip.split('=', 2) }.to_h
      { start: vals['start'].to_s.empty? ? nil : Time.at(vals['start'].to_i),
        end: vals['end'].to_s.empty? ? nil : Time.at(vals['end'].to_i),
        exit: vals['exit'].to_s.empty? ? nil : vals['exit'].to_i }
    end

    def waketime
      out, _err, code = run('sysctl', '-n', 'kern.waketime')
      sec = code.zero? ? out[/sec = (\d+)/, 1].to_i : 0
      sec.positive? ? Time.at(sec) : nil
    end
  end

  # ---------------------------------------------------------------------------
  # State: launchd does not say when a job last ran, so the run counter is
  # watched between refreshes. since = when the job was first seen.
  # ---------------------------------------------------------------------------

  module State
    module_function

    def load
      JSON.parse(File.read(STATE_FILE))
    rescue StandardError
      {}
    end

    def save(state)
      FileUtils.mkdir_p(LOG_DIR)
      tmp = "#{STATE_FILE}.tmp"
      File.write(tmp, JSON.generate(state))
      File.rename(tmp, STATE_FILE)
    rescue StandardError
      nil
    end

    def apply(tasks, now)
      state = load
      tasks.each do |t|
        next unless t.kind == :launchd

        rec = state[t.label] ||= { 'since' => now.to_i, 'runs' => t.runs.to_i, 'run_at' => nil }
        if t.loaded
          runs = t.runs.to_i
          rec['run_at'] = now.to_i if runs > rec['runs'] || (runs < rec['runs'] && runs.positive?)
          rec['runs'] = runs
        end
        t.since = Time.at(rec['since'])
        t.seen_run = rec['run_at'] && Time.at(rec['run_at'])
      end
      live = tasks.map(&:label)
      state.select! { |label, _| live.include?(label) }
      save(state)
    end
  end

  # ---------------------------------------------------------------------------
  # Evaluating: last run, next run, result
  # ---------------------------------------------------------------------------

  module Eval
    module_function

    def evaluate(task, now, wake)
      task.status = Source.read_status(task.slug) if task.wrapped?
      last_run(task)
      next_run(task, now)

      st = task.status
      task.exit_code = st[:exit] if st && st[:end]
      task.failed = task.own? && task.loaded && !task.exit_code.nil? && !task.exit_code.zero? &&
                    !(task.always && task.running)
      task.overdue = overdue?(task, now, wake)
      task.result = result(task, now)
    end

    def last_run(task)
      st = task.status
      if st && st[:start]
        task.last_run = st[:end] || st[:start]
        task.last_src = :ran
        return
      end
      seen = task.seen_run
      mtimes = task.outputs.select { |f| File.exist?(f) }.map { |f| File.mtime(f) }
      newest_output = mtimes.max
      if seen && (newest_output.nil? || seen >= newest_output)
        task.last_run = seen
        task.last_src = :seen
      elsif newest_output
        task.last_run = newest_output
        task.last_src = :output
      end
    end

    def next_run(task, now)
      return if task.always || task.cron? && task.specs.empty?

      candidates = []
      candidates << Schedule.next_of(task.specs, now) unless task.specs.empty?
      if task.interval
        anchor = task.last_run || (task.wrapped? ? File.mtime(task.plist) : task.since) || now
        anchor = now if anchor > now
        steps = ((now - anchor) / task.interval).floor + 1
        candidates << anchor + steps * task.interval
        task.next_approx = task.last_run.nil? || task.last_src == :output
      end
      task.next_run = candidates.compact.min
    end

    # The latest scheduled time has passed with no sign of a run since, and
    # the job was being watched (or created) before that time.
    def overdue?(task, now, wake)
      return false if !task.own? || task.always || task.specs.empty? || !task.loaded || task.disabled || task.running
      return false if wake && now - wake < WAKE_GRACE

      due = Schedule.prev_of(task.specs, now - GRACE)
      return false unless due

      since = task.wrapped? ? File.mtime(task.plist) : task.since
      # A plist edited after the due time had another schedule then: a time
      # moved to earlier today was not missed.
      since = [since, File.mtime(task.plist)].max if since && task.plist && File.exist?(task.plist)
      return false if since.nil? || due <= since

      task.last_run.nil? || task.last_run < due
    end

    def result(task, now)
      return :unloaded unless task.loaded
      return :failed if task.failed
      return :overdue if task.overdue
      return :always if task.always
      return :running if task.running
      return :soon if task.own? && task.next_run && task.next_run - now <= SOON
      return :unknown if task.cron?

      :ok
    end
  end

  ICONS = {
    ok: '✅', failed: '❌', unloaded: '⏳', overdue: '⚠️', soon: '🕒',
    always: '🟢', running: '🏃', unknown: '➖'
  }.freeze

  TEXT = {
    ok: 'ok', failed: 'failed', unloaded: 'not loaded', overdue: 'overdue', soon: 'due soon',
    always: 'always on', running: 'running', unknown: 'no run info'
  }.freeze

  def self.collect(now = Time.now)
    tasks = Source.launchd_tasks + Source.cron_tasks
    State.apply(tasks, now)
    wake = Source.waketime
    tasks.each { |t| Eval.evaluate(t, now, wake) }
    tasks
  end

  def self.find(tasks, name)
    name = name.to_s
    tasks.find { |t| t.name == name || t.label == name } ||
      raise(Error, "no task named #{name} (try: task list)")
  end

  def self.result_text(task)
    text = TEXT[task.result]
    text += " (#{task.exit_code})" if task.result == :failed
    text += " pid #{task.pid}" if task.result == :always && task.pid
    text
  end

  def self.last_text(task, now)
    return 'unknown' unless task.last_run

    case task.last_src
    when :output then "output #{Fmt.stamp(task.last_run, now)}"
    else Fmt.stamp(task.last_run, now)
    end
  end

  def self.next_text(task, now)
    return task.always ? '-' : 'unknown' unless task.next_run
    return '-' if task.result == :unloaded

    "#{task.next_approx ? '~' : ''}#{Fmt.next_short(task.next_run, now)}"
  end

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  module Dialog
    module_function

    def run(script, *args)
      out, err, status = Open3.capture3('osascript', '-e', script, *args)
      return out.strip if status.success?
      raise Cancelled, 'cancelled' if err.include?('-128')

      raise Error, "dialog failed: #{err.strip}"
    end

    def ask(prompt, default = '')
      run(<<~SCRIPT, prompt, default)
        on run argv
          tell application "System Events"
            activate
            set r to display dialog (item 1 of argv) default answer (item 2 of argv) with title "New task" buttons {"Cancel", "OK"} default button "OK"
            return text returned of r
          end tell
        end run
      SCRIPT
    end

    def choose(prompt, items)
      out = run(<<~SCRIPT, prompt, *items)
        on run argv
          tell application "System Events"
            activate
            set picked to choose from list (items 2 thru -1 of argv) with prompt (item 1 of argv) with title "New task"
            if picked is false then error number -128
            return item 1 of picked
          end tell
        end run
      SCRIPT
      out
    end

    def confirm(message, button)
      run(<<~SCRIPT, message, button)
        on run argv
          tell application "System Events"
            activate
            display dialog (item 1 of argv) with title "Tasks" buttons {"Cancel", item 2 of argv} default button "Cancel" cancel button "Cancel" with icon caution
          end tell
        end run
      SCRIPT
    end

    def inform(message)
      run(<<~SCRIPT, message)
        on run argv
          tell application "System Events"
            activate
            display dialog (item 1 of argv) with title "Tasks" buttons {"OK"} default button "OK"
          end tell
        end run
      SCRIPT
    end

    def notify(message)
      run(<<~SCRIPT, message)
        on run argv
          display notification (item 1 of argv) with title "Tasks"
        end run
      SCRIPT
    end
  end

  class Actions
    def initialize(gui)
      @gui = gui
    end

    def say(message)
      if @gui then Dialog.notify(message)
      else puts message
      end
    end

    def tasks
      @tasks ||= Tasks.collect
    end

    def launchctl(*args)
      out, err, code = Source.run('launchctl', *args)
      raise Error, "launchctl #{args.first} failed: #{(err.empty? ? out : err).strip}" unless code.zero?
    end

    def run_now(name)
      task = Tasks.find(tasks, name)
      if task.cron?
        pid = Process.spawn('/bin/sh', '-c', task.command, %i[in out err] => File::NULL, pgroup: true)
        Process.detach(pid)
        say("Started #{task.name} with /bin/sh (not cron's environment).")
      else
        raise Error, "#{task.name} is not loaded (task enable #{task.name})" unless task.loaded

        launchctl('kickstart', '-k', "#{DOMAIN}/#{task.label}")
        say("Started #{task.name}.")
      end
    end

    def disable(name)
      task = launchd(name)
      Source.run('launchctl', 'bootout', "#{DOMAIN}/#{task.label}") if task.loaded
      launchctl('disable', "#{DOMAIN}/#{task.label}")
      say("Disabled #{task.name}: unloaded now and stays off after a reboot.")
    end

    def enable(name)
      task = launchd(name)
      launchctl('enable', "#{DOMAIN}/#{task.label}")
      launchctl('bootstrap', DOMAIN, task.plist) unless task.loaded
      say("Enabled #{task.name}: loaded now and loads at login.")
    end

    def remove(name, yes)
      task = launchd(name)
      raise Error, "#{task.name} was not made by `task add`; remove it by hand" unless task.wrapped?

      files = [task.plist] + %w[log status].map { |e| File.join(LOG_DIR, "#{task.slug}.#{e}") }
      files = files.select { |f| File.exist?(f) }
      unless yes
        Dialog.confirm("Move task #{task.name} to the Trash?\n\nIt is unloaded and its plist, log and status file go to the Trash.", 'Move to Trash')
      end
      Source.run('launchctl', 'bootout', "#{DOMAIN}/#{task.label}") if task.loaded
      Source.run('launchctl', 'enable', "#{DOMAIN}/#{task.label}") if task.disabled
      out, err, code = Source.run(TRASH, *files)
      raise Error, "trash failed: #{(err.empty? ? out : err).strip}" unless code.zero?

      say("Removed #{task.name} (plist, log and status are in the Trash).")
    end

    def launchd(name)
      task = Tasks.find(tasks, name)
      raise Error, "#{task.name} is a cron entry; edit it with `crontab -e`" if task.cron?

      task
    end

    # ---- add ---------------------------------------------------------------

    def add(args)
      opts = parse_add(args)
      opts[:name] ||= Dialog.ask('Name of the task (letters, digits and dashes):')
      opts[:cmd] ||= Dialog.ask('Command (run with bash):')
      opts[:schedule] ||= ask_schedule

      slug = slugify(opts[:name])
      command = opts[:cmd].to_s.strip
      validate_command(command)
      sched = opts[:schedule]
      label = "#{LABEL_PREFIX}#{slug}"
      plist = File.join(AGENT_DIR, "#{label}.plist")
      if File.exist?(plist) || Source.launchctl_info(label)[:loaded]
        raise Error, "#{label} already exists"
      end

      FileUtils.mkdir_p(LOG_DIR)
      File.open(plist, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |f|
        f.write(plist_xml(label, slug, command, sched))
      end
      _out, err, code = Source.run('plutil', '-lint', plist)
      unless code.zero?
        Source.run(TRASH, plist)
        raise Error, "generated plist is invalid: #{err.strip}"
      end
      Source.run('launchctl', 'enable', "#{DOMAIN}/#{label}") if Source.print_disabled[label]
      begin
        launchctl('bootstrap', DOMAIN, plist)
      rescue Error
        Source.run(TRASH, plist)
        raise
      end

      now = Time.now
      nxt = sched[:interval] ? now + sched[:interval] : Schedule.next_of(sched[:specs], now)
      msg = "Added #{slug}\nSchedule: #{sched[:text]}\nNext run: #{nxt ? Fmt.next_long(nxt, now) : 'unknown'}\nPlist: #{plist}"
      @gui || !opts[:interactive] ? say_block(msg) : Dialog.inform(msg)
    end

    def say_block(msg)
      puts msg unless @gui
      Dialog.inform(msg) if @gui
    end

    def parse_add(args)
      opts = { interactive: true }
      args = args.dup
      until args.empty?
        flag = args.shift
        case flag
        when '--name' then opts[:name] = args.shift
        when '--cmd', '--command' then opts[:cmd] = args.shift
        when '--every' then opts[:schedule] = every(args.shift)
        when '--hourly'
          minute = args.first =~ /\A\d+\z/ ? args.shift : '0'
          opts[:schedule] = hourly(minute)
        when '--daily' then opts[:schedule] = daily(args.shift, nil)
        when '--weekdays' then opts[:schedule] = daily(args.shift, [1, 2, 3, 4, 5])
        when '--weekly' then opts[:schedule] = weekly(args.shift)
        else raise Error, "unknown option #{flag} (see: task help)"
        end
      end
      opts[:interactive] = false if opts[:name] && opts[:cmd] && opts[:schedule]
      opts
    end

    def slugify(name)
      slug = name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
      raise Error, 'name needs at least one letter or digit' if slug.empty?
      raise Error, 'name is too long (40 characters at most)' if slug.size > 40
      raise Error, "#{slug} clashes with cron entry names" if slug =~ /\Acron-\d+\z/

      slug
    end

    def validate_command(command)
      raise Error, 'command is empty' if command.empty?
      raise Error, 'command must be one line' if command =~ /[\n\r\0]/
      raise Error, 'command is too long' if command.size > 2000

      _out, err, code = Source.run('/bin/bash', '-n', '-c', command)
      raise Error, "command has a shell syntax error: #{err.strip}" unless code.zero?
    end

    def time_of(text)
      m = text.to_s.strip.match(/\A(\d{1,2}):(\d{2})\z/)
      raise Error, "time must be HH:MM, got #{text.inspect}" unless m && m[1].to_i < 24 && m[2].to_i < 60

      [m[1].to_i, m[2].to_i]
    end

    def every(text)
      m = text.to_s.strip.match(/\A(\d+)\s*(m|min|h)?\z/)
      raise Error, "every needs a number of minutes, e.g. 15m or 2h, got #{text.inspect}" unless m

      seconds = m[1].to_i * (m[2] == 'h' ? 3600 : 60)
      raise Error, 'interval must be at least 1 minute' if seconds < 60

      { interval: seconds, text: Schedule.interval_text(seconds) }
    end

    def hourly(minute)
      raise Error, 'minute must be 0-59' unless minute.to_i.between?(0, 59) && minute.to_s =~ /\A\d+\z/

      spec = Spec.new([minute.to_i], nil, nil, nil, nil)
      { specs: [spec], calendar: [{ 'Minute' => minute.to_i }], text: Schedule.describe([spec]) }
    end

    def daily(text, weekdays)
      h, m = time_of(text)
      days = weekdays || [nil]
      specs = days.map { |d| Spec.new([m], [h], nil, nil, d && [d]) }
      cal = days.map { |d| { 'Hour' => h, 'Minute' => m }.merge(d ? { 'Weekday' => d } : {}) }
      { specs: specs, calendar: cal, text: Schedule.describe(specs).sub('; ', ', ') }.tap do |s|
        s[:text] = "weekdays #{format('%02d:%02d', h, m)}" if weekdays
      end
    end

    def weekly(text)
      day, time = text.to_s.split(/[@\s]+/, 2)
      wd = DAY_NAMES.index(day.to_s.downcase[0, 3])
      raise Error, "weekly needs DAY@HH:MM (e.g. mon@09:00), got #{text.inspect}" unless wd && time

      h, m = time_of(time)
      spec = Spec.new([m], [h], nil, nil, [wd])
      { specs: [spec], calendar: [{ 'Hour' => h, 'Minute' => m, 'Weekday' => wd }], text: Schedule.describe([spec]) }
    end

    def ask_schedule
      kind = Dialog.choose('How often?', ['every N minutes', 'hourly', 'daily at HH:MM',
                                         'weekdays at HH:MM', 'weekly on DAY at HH:MM'])
      case kind
      when 'every N minutes' then every("#{Dialog.ask('Every how many minutes?', '15')}m")
      when 'hourly' then hourly(Dialog.ask('At which minute past the hour (0-59)?', '0'))
      when 'daily at HH:MM' then daily(Dialog.ask('At what time (HH:MM, 24 hour)?', '09:00'), nil)
      when 'weekdays at HH:MM' then daily(Dialog.ask('At what time (HH:MM, 24 hour)?', '09:00'), [1, 2, 3, 4, 5])
      else
        day = Dialog.choose('Which day?', %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday])
        weekly("#{day[0, 3]}@#{Dialog.ask('At what time (HH:MM, 24 hour)?', '09:00')}")
      end
    end

    def xml(value, depth = 1)
      pad = "\t" * depth
      case value
      when Hash
        "<dict>\n#{value.map { |k, v| "#{pad}\t<key>#{CGI.escapeHTML(k)}</key>\n#{pad}\t#{xml(v, depth + 1)}\n" }.join}#{pad}</dict>"
      when Array
        "<array>\n#{value.map { |v| "#{pad}\t#{xml(v, depth + 1)}\n" }.join}#{pad}</array>"
      when Integer then "<integer>#{value}</integer>"
      when true then '<true/>'
      when false then '<false/>'
      else "<string>#{CGI.escapeHTML(value.to_s)}</string>"
      end
    end

    def plist_xml(label, slug, command, sched)
      data = {
        'Label' => label,
        'ProgramArguments' => ['/bin/bash', WRAPPER, slug, command],
        'WorkingDirectory' => HOME,
        'EnvironmentVariables' => { 'PATH' => TASK_PATH },
        'RunAtLoad' => false
      }
      if sched[:interval]
        data['StartInterval'] = sched[:interval]
      else
        cal = sched[:calendar]
        data['StartCalendarInterval'] = cal.size == 1 ? cal.first : cal
      end
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" \
        "<plist version=\"1.0\">\n#{xml(data, 0)}\n</plist>\n"
    end
  end

  # ---------------------------------------------------------------------------
  # Views
  # ---------------------------------------------------------------------------

  SORT = { failed: 0, overdue: 0, soon: 1, running: 2, ok: 2, unknown: 2, always: 3, unloaded: 4 }.freeze

  def self.sorted(tasks)
    tasks.sort_by do |t|
      [SORT[t.result], t.next_run ? t.next_run.to_i : Float::INFINITY, t.name]
    end
  end

  def self.list(tasks, now = Time.now)
    if tasks.empty?
      puts 'No scheduled tasks.'
      return
    end
    rows = sorted(tasks).map do |t|
      ["#{ICONS[t.result]} #{result_text(t)}", t.name, t.schedule, next_text(t, now), last_text(t, now)]
    end
    head = %w[STATUS NAME SCHEDULE NEXT LAST]
    widths = head.each_index.map { |i| ([head[i]] + rows.map { |r| r[i] }).map { |c| display_width(c) }.max }
    [head, *rows].each do |row|
      puts row.each_with_index.map { |c, i| c + ' ' * (widths[i] - display_width(c)) }.join('  ').rstrip
    end
    puts
    puts NOTE
  end

  NOTE = "Overdue = it didn't run when scheduled. launchd does not run jobs missed while the Mac " \
         'was off; after sleep it runs one catch-up.'

  def self.display_width(text)
    text.each_char.sum { |c| c.ord == 0xFE0F ? 0 : (c.ord > 0x2000 ? 2 : 1) }
  end

  class Menu
    PREFIX = '⏱'
    RED = '#ff453a,#d70015'
    GRAY = '#8e8e93'

    def initialize(printer, tasks, now)
      @p = printer
      @tasks = tasks
      @now = now
    end

    def render
      bad = @tasks.select { |t| %i[failed overdue].include?(t.result) }
      soon = @tasks.select { |t| t.result == :soon }
      title = "#{PREFIX}#{soon.size}#{bad.empty? ? '' : '!'}"
      props = { dropdown: false }
      if bad.any? then props[:color] = RED
      elsif soon.empty? then props[:color] = GRAY
      end
      @p.item(title, **props)
      @p.sep
      @p.item('➕ Add task…', rpc: %w[--gui add], refresh: true)
      @p.item('↻ Refresh', refresh: true)

      group('Overdue / failed', bad, RED)
      group('Due soon (next 3h)', soon)
      later = @tasks.select { |t| %i[ok running unknown].include?(t.result) }
      group('Later', later)
      group('Always on', @tasks.select { |t| t.result == :always })
      group('Not loaded', @tasks.select { |t| t.result == :unloaded })
      @p.item('No scheduled tasks found') if @tasks.empty?

      @p.sep
      @p.item('Open logs folder', shell: ['/usr/bin/open', LOG_DIR]) if File.directory?(LOG_DIR)
      @p.item('Edit crontab…', terminal: true, shell: ['/usr/bin/crontab', '-e'])
      @p.item('Overdue = it did not run when scheduled', size: 11, color: GRAY) do |sub|
        sub.item("launchd does not run jobs missed while the Mac was off.", size: 11)
        sub.item('After sleep it runs one catch-up, so only a Mac that was off', size: 11)
        sub.item('(or a job that failed to start) shows as overdue.', size: 11)
        sub.item('Last run of older agents is best effort (log time, or when this menu saw the run).', size: 11)
      end
    end

    private

    def group(title, tasks, color = GRAY)
      return if tasks.empty?

      @p.sep
      @p.item("#{title} (#{tasks.size})", size: 12, color: color)
      Tasks.sorted(tasks).each { |t| row(t) }
    end

    def clean(text, max = 150)
      text = text.to_s.tr('|', '¦').tr("\n", ' ')
      text.length > max ? "#{text[0, max - 1]}…" : text
    end

    def row(task)
      parts = [task.name, task.schedule]
      case task.result
      when :always then parts << (task.pid ? "pid #{task.pid}" : 'running')
      when :unloaded then parts << (task.disabled ? 'disabled' : 'not loaded')
      when :failed then parts << "exit #{task.exit_code}"
      when :overdue then parts << "missed #{Fmt.stamp(Schedule.prev_of(task.specs, @now - GRACE), @now)}"
      else parts << Tasks.next_text(task, @now) if task.next_run
      end
      @p.item(clean("#{ICONS[task.result]} #{parts.join(' · ')}")) { |sub| details(sub, task) }
    end

    def details(sub, task)
      if task.cron?
        sub.item('▶ Run now (shell, not cron environment)', rpc: ['--gui', 'run', task.name], refresh: true)
      elsif task.loaded
        sub.item(task.always ? '▶ Restart (kickstart -k)' : '▶ Run now (kickstart -k)',
                 rpc: ['--gui', 'run', task.name], refresh: true)
        sub.item('⏸ Disable (unload + stays off after reboot)', rpc: ['--gui', 'disable', task.name], refresh: true)
      else
        sub.item('⏵ Enable (load + loads at login)', rpc: ['--gui', 'enable', task.name], refresh: true)
      end
      if task.wrapped?
        sub.item('🗑 Remove…', rpc: ['--gui', 'rm', task.name], refresh: true)
      end

      unless task.cron?
        sub.sep
        log = task.log_path
        if log && File.exist?(log)
          sub.item('Open log', shell: ['/usr/bin/open', log])
        else
          sub.item('Open log (none yet)')
        end
        sub.item('Reveal plist in Finder', shell: ['/usr/bin/open', '-R', task.plist])
        sub.item('Edit plist', shell: ['/usr/bin/open', '-t', task.plist])
      end

      sub.sep
      sub.item(clean("Command: #{task.command}"))
      sub.item("Schedule: #{task.schedule}")
      sub.item("Next run: #{next_line(task)}") unless task.always
      sub.item("#{task.last_src == :output ? 'Last output' : 'Last run'}: #{last_line(task)}")
      sub.item("Last exit: #{exit_line(task)}")
      sub.item("Result: #{Tasks.result_text(task)}")
      sub.item("Runs since load: #{task.runs}") if task.runs
      sub.item("Plist: #{task.plist}") if task.plist
      sub.item("Label: #{task.label}") unless task.cron?
    end

    def next_line(task)
      return 'unknown' unless task.next_run

      "#{task.next_approx ? '~' : ''}#{Fmt.next_long(task.next_run, @now)}"
    end

    def last_line(task)
      return 'unknown (no status file, no log written)' unless task.last_run

      text = Fmt.last_long(task.last_run, @now)
      case task.last_src
      when :output then "#{text} (log modified; run time unknown)"
      when :seen then "#{text}, seen by this menu"
      else text
      end
    end

    def exit_line(task)
      return 'never exited (running)' if task.exit_code.nil? && task.running
      return 'unknown' if task.exit_code.nil?

      task.exit_code.to_s
    end
  end

  HELP = <<~TEXT
    task list                     scheduled tasks: what runs when, last run, result
    task add [--name N --cmd C SCHEDULE]
                                  new launchd task; dialogs ask for what is missing
        SCHEDULE: --every 15m | --every 2h | --hourly [MIN] | --daily HH:MM
                  --weekdays HH:MM | --weekly mon@HH:MM
    task run NAME                 start it now (launchctl kickstart -k; cron entries run in a shell)
    task enable|disable NAME      load or unload now and for every login
    task rm NAME [--yes]          unload and move a task made by `task add` to the Trash (asks first)
  TEXT

  def self.cli(argv)
    gui = !argv.delete('--gui').nil?
    cmd = argv.shift
    actions = Actions.new(gui)
    case cmd
    when 'list', 'ls' then list(collect)
    when 'add' then actions.add(argv)
    when 'run' then actions.run_now(need(argv))
    when 'enable' then actions.enable(need(argv))
    when 'disable' then actions.disable(need(argv))
    when 'rm', 'remove' then actions.remove(need(argv), argv.include?('--yes'))
    when 'help', '-h', '--help' then puts HELP
    else raise Error, "unknown command #{cmd} (see: task help)"
    end
  end

  def self.need(argv)
    argv.reject { |a| a.start_with?('--') }.first || raise(Error, 'which task? (see: task list)')
  end

  def self.menu
    now = Time.now
    printer = MenuKit::Printer.new
    Menu.new(printer, collect(now), now).render
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV.empty?
      Tasks.menu
    else
      begin
        Tasks.cli(ARGV.dup)
      rescue Tasks::Cancelled
        exit 0
      rescue Tasks::Error, ArgumentError => e
        if ARGV.include?('--gui')
          Tasks::Dialog.notify("Error: #{e.message}") rescue nil
        end
        warn "task: #{e.message}"
        exit 1
      end
    end
  rescue StandardError => e
    MenuKit.crash(e)
  end
end
