#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Loadout</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.desc>Presets for what runs on this Mac: pick one and services, queue workers, launchd jobs and apps start or stop to match</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>
#
# Presets live in ~/.config/quietbar/presets.yml (format explained at the top of
# presets.example.yml, which install.sh copies there).
# Also a CLI:
#   loadout.1m.rb status
#   loadout.1m.rb apply NAME [--dry-run]
#   loadout.1m.rb save NAME [--force]
# --file PATH (or LOADOUT_FILE) uses another preset file.
# Services are started and stopped through bin/svc.sh, launchd agents with launchctl.

require 'fileutils'
require 'open3'
require 'timeout'
require 'tmpdir'
require 'yaml'

ENV['PATH'] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:#{ENV['PATH']}"
Encoding.default_external = Encoding::UTF_8

require_relative '../lib/menu_kit'

# Loadout reads the running state, compares it with a preset and makes them match.
module Loadout
  PREFIX = '◧'
  TITLE = 'Loadout'

  SVC = File.expand_path('../bin/svc.sh', __dir__)
  # Optional: only used when supervisord is installed.
  SUPERVISOR_CONF = ENV['SUPERVISOR_CONF'] ||
                    "#{File.directory?('/opt/homebrew') ? '/opt/homebrew' : '/usr/local'}/etc/supervisord.conf"
  DEFAULT_FILE = File.expand_path('~/.config/quietbar/presets.yml')
  # launchd labels that start with this are yours (QUIETBAR_LABEL_PREFIX)
  AGENT_PREFIX = ENV['QUIETBAR_LABEL_PREFIX'] || 'local.quietbar'
  APP_DIRS = %w[/Applications /System/Applications /Applications/Utilities
                /System/Applications/Utilities ~/Applications].map { |d| File.expand_path(d) }.freeze
  SECTIONS = %w[on off open quit].freeze
  NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/.freeze
  OPPOSITE = { start: 'off', stop: 'on', open: 'quit', quit: 'open' }.freeze
  YAML_WORDS = %w[on off yes no true false null y n].freeze

  # A thing a preset names. kind: :service, :agent, :app or :bad (error says why).
  Item = Struct.new(:kind, :name, :runner, :error, keyword_init: true) do
    def key
      "#{kind}:#{name}"
    end

    def label
      case kind
      when :service then "#{name} (#{runner})"
      when :agent then "#{name} (launchd)"
      when :app then "#{name} (app)"
      else name.to_s
      end
    end
  end

  Step = Struct.new(:action, :item, keyword_init: true) do
    def stop?
      %i[stop quit].include?(action)
    end
  end

  Plan = Struct.new(:name, :steps, :kept, :constraints, keyword_init: true) do
    def errors
      steps.select { |s| s.action == :error }
    end

    def changes
      steps - errors
    end

    def starts
      changes.reject(&:stop?)
    end

    def stops
      changes.select(&:stop?)
    end

    def clean?
      steps.empty?
    end
  end

  Svc = Struct.new(:name, :runner, :state, keyword_init: true) do
    def running?
      %w[started starting].include?(state)
    end
  end

  class UserError < StandardError; end

  # What is running right now: svc's table, launchd and one ps listing.
  class Snapshot
    attr_reader :services, :agents

    def self.capture
      new(sh(Loadout::SVC, 'list').first)
    end

    def self.sh(*args)
      out, err, status = Open3.capture3(*args)
      [out.dup.force_encoding('UTF-8'), err.dup.force_encoding('UTF-8'), status]
    rescue SystemCallError => e
      ['', e.message, nil]
    end

    def initialize(svc_table)
      @services = parse_table(svc_table)
      @agents = launchd_list
      load_processes
      load_supervisor_pids
    end

    def service(name)
      services.find { |s| s.name == name }
    end

    def running?(item)
      case item.kind
      when :service then service(item.name)&.running? || false
      when :agent then agents.key?(item.name)
      when :app then !app_pids(item.name).empty?
      else false
      end
    end

    # Rough resident memory in KB, 0 when not running.
    def mem_kb(item)
      pids = case item.kind
             when :service then service_pids(item)
             when :agent then [agents[item.name]].compact
             when :app then return app_pids(item.name).sum { |p| @rss[p] }
             else []
             end
      # supervisor's own process is counted without the programs it runs
      tree = item.name == 'supervisor' ? false : true
      pids.sum { |p| tree ? subtree_kb(p) : @rss.fetch(p, 0) }
    end

    def running_agents
      agents.select { |label, pid| label.start_with?(Loadout::AGENT_PREFIX) && pid }.keys.sort
    end

    private

    def parse_table(out)
      out.each_line.each_with_object([]) do |line, memo|
        m = line.match(/\A│ (\S+)\s+│ (brew|supervisor)\s+│ \S (.+?)\s*│\s*\z/)
        next unless m

        state = m[3].start_with?('stopped') ? 'stopped' : m[3].split.first
        memo << Svc.new(name: m[1], runner: m[2].to_sym, state: state)
      end
    end

    # label => pid or nil
    def launchd_list
      out, = self.class.sh('launchctl', 'list')
      out.each_line.drop(1).each_with_object({}) do |line, memo|
        pid, _status, label = line.strip.split(/\s+/, 3)
        memo[label] = pid == '-' ? nil : pid.to_i if label
      end
    end

    def load_processes
      @rss = Hash.new(0)
      @kids = Hash.new { |h, k| h[k] = [] }
      @cmd = {}
      out, = self.class.sh('ps', '-axo', 'pid=,ppid=,rss=,command=')
      out.each_line do |line|
        m = line.chomp.match(/\A\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)\z/)
        next unless m

        pid = m[1].to_i
        @rss[pid] = m[3].to_i
        @kids[m[2].to_i] << pid
        @cmd[pid] = m[4]
      end
    end

    def load_supervisor_pids
      @sup = Hash.new { |h, k| h[k] = [] }
      out, = self.class.sh('supervisorctl', '-c', Loadout::SUPERVISOR_CONF, 'status')
      out.each_line do |line|
        m = line.match(/\A(\S+)\s+RUNNING\s+pid (\d+)/)
        @sup[m[1].split(':').first] << m[2].to_i if m
      end
    end

    def service_pids(item)
      svc = service(item.name)
      return [] unless svc&.running?
      return @sup[svc.name] if svc.runner == :supervisor

      [agents["sh.brew.#{svc.name}"], agents["homebrew.mxcl.#{svc.name}"]].compact
    end

    def subtree_kb(pid, seen = {})
      return 0 if seen[pid]

      seen[pid] = true
      @rss.fetch(pid, 0) + @kids[pid].sum { |k| subtree_kb(k, seen) }
    end

    def app_pids(name)
      marker = "/#{name}.app/"
      @cmd.select { |_pid, cmd| cmd.include?(marker) }.keys
    end
  end

  class Menu
    include MenuKit::Commands

    # Public methods are the CLI and the menu's click handlers.

    def run
      snap = Snapshot.capture
      presets, problems = load_presets
      plans = presets.map { |name, spec| build_plan(name, spec, snap) }
      active = active_plan(plans)
      managed = plans.flat_map { |p| p.steps.map(&:item) + p.kept }.reject { |i| i.kind == :bad }.uniq(&:key)

      title = active ? active.name : "Custom #{managed.count { |i| snap.running?(i) }}/#{managed.size}"
      printer.item("#{PREFIX} #{title}", dropdown: false)
      printer.sep
      printer.item('Presets')
      problems.each { |msg| printer.item("⚠ #{truncate(msg)}", color: 'orange') }
      plans.each { |plan| print_preset(plan, plan == active, snap) }
      printer.item('No presets, add some with Edit presets…') if plans.empty?

      printer.sep
      print_running(snap, managed)

      printer.sep
      printer.item('Save current state as preset…', rpc: ['prompt_save'])
      printer.item('Edit presets…', shell: ['/usr/bin/open', '-t', presets_file])
      printer.item('⏳ Refresh', alt: '⏳ Refresh (⌘R)', refresh: true)
    end

    def status(*args)
      parse_args(args)
      snap = Snapshot.capture
      presets, problems = load_presets
      plans = presets.map { |name, spec| build_plan(name, spec, snap) }
      active = active_plan(plans)
      managed = plans.flat_map { |p| p.steps.map(&:item) + p.kept }.reject { |i| i.kind == :bad }.uniq(&:key)

      puts "Active: #{active ? active.name : "Custom (#{managed.count { |i| snap.running?(i) }}/#{managed.size} of the listed things running)"}"
      problems.each { |msg| puts "Problem: #{msg}" }
      puts
      puts "Presets (#{presets_file}):"
      plans.each do |plan|
        puts format('  %s %-14s %s', plan == active ? '✓' : ' ', plan.name, summary(plan, snap))
      end
      puts
      puts 'Running:'
      total = 0
      running_items(snap, managed).each do |item, on|
        mem = on ? snap.mem_kb(item) : 0
        total += mem
        puts format('  %s %-34s %s', on ? '●' : '○', item.label, on ? mb(mem) : '')
      end
      puts format('  %-36s %s', 'total of the above', mb(total))
    end

    def apply(*args)
      opts, rest = parse_args(args)
      name = rest.first or raise UserError, 'usage: apply NAME [--dry-run]'
      snap = Snapshot.capture
      plan = plan_for(name, snap)
      print_plan(plan, snap, opts[:dry])
      return if opts[:dry]

      execute(plan, snap, opts[:notify])
    end

    # Menu click: confirm in a dialog, then apply.
    def pick(*args)
      name = parse_args(args).last.first
      snap = Snapshot.capture
      plan = plan_for(name, snap)
      if plan.clean?
        notify("#{TITLE}: #{name}", 'Already matches, nothing to change.')
        return
      end
      return unless dialog(confirm_text(plan, snap), %w[Cancel Apply], 'Apply')

      execute(plan, snap, true)
    rescue UserError => e
      notify("#{TITLE}: #{name}", e.message)
    ensure
      refresh_menu
    end

    def save(*args)
      opts, rest = parse_args(args)
      name = rest.first or raise UserError, 'usage: save NAME [--force]'
      write_preset(name, opts[:force], Snapshot.capture)
    end

    # Menu click: ask for a name, then save.
    def prompt_save(*_args)
      name = ask('Name for the preset (it will start everything running now):')
      return if name.nil? || name.empty?

      begin
        force = false
        if load_presets.first.key?(name)
          return unless dialog("A preset called #{name} exists. Replace it with the running state?", %w[Cancel Replace], 'Replace')

          force = true
        end
        write_preset(name, force, Snapshot.capture)
        notify("#{TITLE}: saved", "Saved #{name}. Edit presets… to trim it.")
      rescue UserError => e
        notify("#{TITLE}: not saved", e.message)
      end
      refresh_menu
    end

    private

    def parse_args(args)
      opts = { dry: false, force: false, notify: true }
      rest = []
      list = args.dup
      until list.empty?
        arg = list.shift
        case arg
        when '--dry-run', '-n' then opts[:dry] = true
        when '--force' then opts[:force] = true
        when '--no-notify' then opts[:notify] = false
        when '--file' then @file = File.expand_path(list.shift.to_s)
        when /\A--file=(.+)/ then @file = File.expand_path(Regexp.last_match(1))
        else rest << arg
        end
      end
      [opts, rest]
    end

    def presets_file
      @file || ENV['LOADOUT_FILE'] || DEFAULT_FILE
    end

    def agent_dir
      File.expand_path(ENV['LOADOUT_AGENT_DIR'] || '~/Library/LaunchAgents')
    end

    def uid
      Process.uid
    end

    #
    # Presets
    #

    # Returns [{name => {'on' => [...], ...}}, [problem messages]].
    def load_presets
      file = presets_file
      unless File.file?(file)
        # No file yet is fine at the default place; saving a preset creates it.
        return [{}, []] if file == DEFAULT_FILE

        return [{}, ["#{file} not found"]]
      end

      data = YAML.safe_load(File.read(file), permitted_classes: [], aliases: false) || {}
      return [{}, ["#{file}: expected preset names at the top level"]] unless data.is_a?(Hash)

      problems = []
      presets = {}
      data.each do |name, body|
        if !name.is_a?(String) && !name.is_a?(Numeric) || YAML_WORDS.include?(name.to_s.downcase)
          problems << "preset name #{name.inspect} is read as a yes/no or null by YAML, rename it"
          next
        end
        body ||= {}
        unless body.is_a?(Hash)
          problems << "#{name}: expected on:/off:/open:/quit: lists"
          next
        end
        spec = Hash.new { |h, k| h[k] = [] }
        body.each do |key, value|
          # YAML 1.1 reads the keys on and off as true and false
          key = { true => 'on', false => 'off' }.fetch(key, key.to_s)
          if SECTIONS.include?(key)
            spec[key] = Array(value).map(&:to_s)
          else
            problems << "#{name}: unknown key #{key} (use on, off, open, quit)"
          end
        end
        presets[name.to_s] = spec
      end
      [presets, problems]
    rescue Psych::Exception => e
      [{}, ["#{file}: #{e.message.lines.first.to_s.strip}"]]
    end

    def plan_for(name, snap)
      presets, problems = load_presets
      spec = presets[name]
      unless spec
        known = presets.keys.empty? ? '' : " Presets: #{presets.keys.join(', ')}."
        raise UserError, "no preset called #{name}.#{known}#{problems.first && " (#{problems.first})"}"
      end

      build_plan(name, spec, snap)
    end

    # What has to change to make the running state match the preset.
    def build_plan(name, spec, snap)
      steps = []
      kept = []
      seen = {}
      constraints = 0
      { 'on' => :start, 'off' => :stop, 'open' => :open, 'quit' => :quit }.each do |section, action|
        spec[section].each do |raw|
          item = resolve(raw, section, snap)
          constraints += 1
          if item.kind == :bad
            steps << Step.new(action: :error, item: item)
            next
          end
          other = seen[item.key]
          if other && other != action
            steps << Step.new(action: :error,
                              item: Item.new(kind: :bad, name: raw, error: "#{raw} is listed under both #{OPPOSITE.fetch(action)}: and #{section}:"))
            next
          end
          next if other

          seen[item.key] = action
          want_running = %i[start open].include?(action)
          if snap.running?(item) == want_running
            kept << item
          else
            steps << Step.new(action: action, item: item)
          end
        end
      end
      Plan.new(name: name, steps: steps, kept: kept, constraints: constraints)
    end

    def resolve(raw, section, snap)
      raw = raw.strip
      return Item.new(kind: :bad, name: '(empty)', error: 'empty entry') if raw.empty?
      return resolve_app(raw, section) if %w[open quit].include?(section)

      names = snap.services.map(&:name)
      hits = names.include?(raw) ? [raw] : names.select { |n| n.start_with?(raw) }
      return Item.new(kind: :bad, name: raw, error: "'#{raw}' matches #{hits.join(', ')}, use more of the name") if hits.size > 1
      return Item.new(kind: :service, name: hits.first, runner: snap.service(hits.first).runner) if hits.size == 1
      return resolve_agent(raw, snap)
    end

    def resolve_agent(label, snap)
      if label.start_with?('sh.brew.', 'homebrew.mxcl.')
        return Item.new(kind: :bad, name: label, error: "#{label} is a brew service, use its svc name")
      end
      if snap.agents.key?(label) || File.file?(File.join(agent_dir, "#{label}.plist"))
        return Item.new(kind: :agent, name: label)
      end

      Item.new(kind: :bad, name: label, error: "no service or launchd agent called '#{label}'")
    end

    def resolve_app(name, section)
      return Item.new(kind: :app, name: name) if APP_DIRS.any? { |d| File.directory?(File.join(d, "#{name}.app")) }

      Item.new(kind: :bad, name: name, error: "no app called '#{name}' (#{section}:)")
    end

    # The preset whose whole list matches now; the most specific one wins.
    def active_plan(plans)
      plans.select { |p| p.clean? && p.constraints.positive? }.max_by { |p| p.constraints }
    end

    #
    # Menu
    #

    def print_preset(plan, active, snap)
      text = "#{active ? '✓' : "\u2003"} #{plan.name}"
      text += "   #{summary(plan, snap)}" unless active
      printer.item(text, rpc: ['pick', plan.name])
    end

    def summary(plan, snap)
      return 'active' if plan.clean? && plan.constraints.positive?

      parts = []
      parts << "✚ #{plan.starts.size}" unless plan.starts.empty?
      freed = plan.stops.sum { |s| snap.mem_kb(s.item) }
      parts << "✖ #{plan.stops.size}#{freed.positive? ? " (frees ~#{mb(freed)})" : ''}" unless plan.stops.empty?
      parts << "⚠ #{plan.errors.size}" unless plan.errors.empty?
      parts.empty? ? 'empty' : parts.join('  ')
    end

    def print_running(snap, managed)
      items = running_items(snap, managed)
      total = items.sum { |item, on| on ? snap.mem_kb(item) : 0 }
      printer.item("Running now (~#{mb(total)})")
      items.each do |item, on|
        text = "#{on ? '🟢' : '⚪️'} #{item.label}"
        text += " · #{mb(snap.mem_kb(item))}" if on
        printer.item(text)
      end
    end

    # [[item, running?]]: every svc service, running launchd agents, and anything a preset names.
    def running_items(snap, managed)
      items = snap.services.map { |s| Item.new(kind: :service, name: s.name, runner: s.runner) }
      labels = (snap.running_agents + managed.select { |i| i.kind == :agent }.map(&:name)).uniq
      items += labels.map { |l| Item.new(kind: :agent, name: l) }
      items += managed.select { |i| i.kind == :app }
      items.uniq(&:key).map { |i| [i, snap.running?(i)] }
    end

    def mb(kb)
      return "#{(kb / 1024.0 / 1024).round(1)} GB" if kb >= 1_048_576

      "#{(kb / 1024.0).round} MB"
    end

    def truncate(text, max = 140)
      text = text.tr('|', '¦')
      text.length > max ? "#{text[0, max - 1]}…" : text
    end

    #
    # Applying
    #

    def print_plan(plan, snap, dry)
      puts "#{dry ? 'Dry run: ' : ''}#{plan.name}"
      plan.stops.each { |s| puts format('  ✖ stop   %-40s %s', s.item.label, mb(snap.mem_kb(s.item))) }
      plan.starts.each { |s| puts "  ✚ start  #{s.item.label}" }
      plan.errors.each { |s| puts "  ⚠ #{s.item.error}" }
      puts "  already as wanted: #{plan.kept.map(&:name).join(', ')}" unless plan.kept.empty?
      puts '  nothing to change' if plan.changes.empty? && plan.errors.empty?
      freed = plan.stops.sum { |s| snap.mem_kb(s.item) }
      puts "  frees about #{mb(freed)}" if freed.positive?
    end

    def confirm_text(plan, snap)
      lines = ["Apply \"#{plan.name}\"?", '']
      unless plan.stops.empty?
        lines << 'Stops:'
        plan.stops.each { |s| lines << "  ✖ #{s.item.label}" }
        freed = plan.stops.sum { |s| snap.mem_kb(s.item) }
        lines << "  frees about #{mb(freed)}" if freed.positive?
        lines << ''
      end
      unless plan.starts.empty?
        lines << 'Starts:'
        plan.starts.each { |s| lines << "  ✚ #{s.item.label}" }
        lines << ''
      end
      unless plan.errors.empty?
        lines << 'Cannot do (will be reported):'
        plan.errors.each { |s| lines << "  ⚠ #{s.item.error}" }
      end
      lines.join("\n").strip
    end

    # Stops first (frees RAM), then starts. Each step fails on its own.
    def execute(plan, snap, notify_when_done)
      lock = File.open(File.join(Dir.tmpdir, "loadout-#{uid}.lock"), File::CREAT | File::RDWR)
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        raise UserError, 'another apply is already running'
      end

      failures = {}
      ordered = stop_order(plan.stops) + start_order(plan.starts)
      fresh = nil
      ordered.each do |step|
        next if fresh && reached?(fresh, step) # supervisor's autostart already brought it up

        msg = perform(step)
        failures[step] = msg if msg
        next unless step.item.name == 'supervisor' && step.action == :start && !msg

        wait_for_supervisor
        fresh = Snapshot.capture
      end

      snap = verify(ordered, failures)
      done = ordered.size - failures.size
      failures.each { |step, msg| puts "  ⚠ #{step.item.label}: #{msg}" }
      plan.errors.each { |s| failures[s] = s.item.error }
      total = ordered.size + plan.errors.size
      puts "  #{done} of #{total} done" if total.positive?
      if notify_when_done
        notify("#{TITLE}: #{plan.name}", report_text(plan, ordered, failures, done))
      end
      exit 1 unless failures.empty?
      snap
    ensure
      refresh_menu
      lock&.close
    end

    def stop_order(steps)
      rank = ->(s) { { agent: 0, app: 1 }.fetch(s.item.kind) { s.item.runner == :supervisor ? 2 : 3 } }
      steps.sort_by(&rank)
    end

    def start_order(steps)
      rank = lambda do |s|
        case s.item.kind
        when :service then s.item.runner == :brew ? 0 : 1
        when :agent then 2
        else 3
        end
      end
      steps.sort_by(&rank)
    end

    # Returns nil on success, otherwise why it failed.
    def perform(step)
      item = step.item
      case item.kind
      when :service then run_cmd(SVC, step.action.to_s, item.name)
      when :agent then perform_agent(step)
      when :app then perform_app(step)
      end
    end

    def perform_agent(step)
      label = step.item.name
      if step.action == :start
        plist = File.join(agent_dir, "#{label}.plist")
        return "no plist at #{plist}" unless File.file?(plist)

        run_cmd('/bin/launchctl', 'bootstrap', "gui/#{uid}", plist)
      else
        run_cmd('/bin/launchctl', 'bootout', "gui/#{uid}/#{label}")
      end
    end

    def perform_app(step)
      name = step.item.name
      if step.action == :open
        run_cmd('/usr/bin/open', '-g', '-a', name)
      else
        run_cmd('/usr/bin/osascript', '-e', 'on run argv', '-e', 'tell application (item 1 of argv) to quit',
                '-e', 'end run', name)
      end
    end

    def run_cmd(*args)
      out, err, status = Timeout.timeout(90) { Snapshot.sh(*args) }
      return nil if status&.success?

      text = [err, out].map(&:strip).reject(&:empty?).first.to_s.lines.first.to_s.strip
      text.empty? ? "#{File.basename(args.first)} failed" : text
    rescue Timeout::Error
      'timed out after 90s'
    end

    def reached?(snap, step)
      snap.running?(step.item) == %i[start open].include?(step.action)
    end

    # A command can succeed without the thing coming up, so check the state again,
    # giving slow starts and stops a few seconds.
    def verify(steps, failures)
      snap = nil
      8.times do |i|
        sleep 1 if i.positive?
        snap = Snapshot.capture
        break if steps.all? { |s| reached?(snap, s) || failures[s] }
      end
      steps.each do |s|
        if reached?(snap, s)
          failures.delete(s)
        elsif !failures[s]
          failures[s] = if %i[start open].include?(s.action) then 'did not start'
                        elsif s.item.kind == :app then 'still running (may be asking to save)'
                        else 'still running'
                        end
        end
      end
      snap
    end

    def wait_for_supervisor
      20.times do
        _o, _e, status = Snapshot.sh('supervisorctl', '-c', SUPERVISOR_CONF, 'status')
        return if status && status.exitstatus != 4

        sleep 0.5
      end
    end

    def report_text(plan, ordered, failures, done)
      if failures.empty?
        parts = []
        parts << "stopped #{plan.stops.size}" unless plan.stops.empty?
        parts << "started #{plan.starts.size}" unless plan.starts.empty?
        return "Applied: #{parts.join(', ')}."
      end

      bad = failures.map { |step, msg| "#{step.item.name}: #{msg}" }.join('; ')
      "#{failures.size} failed, #{done} ok. #{bad}"[0, 230]
    end

    #
    # Saving
    #

    def write_preset(name, force, snap)
      unless name.match?(NAME_RE) && !YAML_WORDS.include?(name.downcase)
        raise UserError, "preset name '#{name}' must be letters, digits, - or _ (and not yes/no/on/off)"
      end

      items = snap.services.select(&:running?).map(&:name) + snap.running_agents
      raise UserError, 'nothing is running to save' if items.empty?

      block = ["#{name}:", "  # saved #{Time.now.strftime('%F')} from the running state", '  on:']
      items.each { |i| block << "    - #{i}" }

      file = presets_file
      text = File.file?(file) ? File.read(file) : ''
      lines = text.lines.map(&:chomp)
      at = lines.index { |l| l.match?(/\A#{Regexp.escape(name)}:\s*(#.*)?\z/) }
      raise UserError, "preset #{name} already exists (--force to replace it)" if at && !force

      FileUtils.mkdir_p(File.dirname(file))
      File.write("#{file}.bak", text) unless text.empty?
      if at
        stop = at + 1
        stop += 1 while stop < lines.size && (lines[stop].empty? || lines[stop].start_with?(' ', "\t"))
        # keep blank lines that separate this block from the next
        stop -= 1 while stop > at + 1 && lines[stop - 1].empty?
        lines[at...stop] = block
      else
        lines << '' unless lines.empty? || lines.last.empty?
        lines.concat(block)
      end
      File.write(file, "#{lines.join("\n")}\n")
      puts "Saved #{name}: #{items.join(', ')}"
    end

    #
    # Dialogs and notifications
    #

    def osa(lines, *argv)
      out, _err, status = Snapshot.sh('/usr/bin/osascript', *lines.flat_map { |l| ['-e', l] }, *argv)
      status&.success? ? out.strip : nil
    end

    # Returns true when the second button was clicked.
    def dialog(text, buttons, default)
      give_up = ENV['LOADOUT_DIALOG_GIVE_UP'].to_i
      clause = give_up.positive? ? " giving up after #{give_up}" : ''
      list = buttons.map { |b| %("#{b}") }.join(', ')
      show = %(display dialog (item 1 of argv) with title "#{TITLE}" buttons {#{list}} ) +
             %(default button "#{default}" cancel button "#{buttons.first}" with icon note#{clause})
      out = osa(['on run argv', 'tell current application to activate', show, 'end run'], text)
      !out.nil? && !out.include?('gave up:true') && out.include?("button returned:#{default}")
    end

    def ask(prompt)
      show = %(text returned of (display dialog (item 1 of argv) with title "#{TITLE}" default answer "" ) +
             %(buttons {"Cancel", "Save"} default button "Save" cancel button "Cancel"))
      osa(['on run argv', 'tell current application to activate', show, 'end run'], prompt)
    end

    def notify(title, body)
      osa(['on run argv', 'display notification (item 2 of argv) with title (item 1 of argv)', 'end run'],
          title, body)
    end

    def refresh_menu
      return unless system('pgrep', '-xq', 'SwiftBar')

      system('open', '-g', "swiftbar://refreshplugin?name=#{plugin_name}")
    end
  end
end

begin
  service = Loadout::Menu.new
  MenuKit.dispatch(service, ARGV)
rescue Loadout::UserError => e
  warn "loadout: #{e.message}"
  exit 1
rescue StandardError => e
  MenuKit.crash(e)
end
