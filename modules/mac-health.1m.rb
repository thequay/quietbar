#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Mac Health</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.desc>Disk, memory, CPU, battery, Time Machine and uptime of this Mac at a glance</xbar.desc>
# <xbar.dependencies>ruby,python3</xbar.dependencies>
#
# Report only, nothing here changes or cleans anything.
#
# The 1-minute run only does cheap probes (df, sysctl, pmset, uptime, ps).
# Everything slow runs in a detached copy of this script that writes
# ~/.cache/swiftbar-mac-health/<name>.json, and the next refresh picks it up:
#   macstat  macstat.py snapshot, TTL 90s (memory/energy per app, user/sys CPU)
#   sizes    du over a short fixed list of dev folders, TTL 30m
#   backup   tmutil latestbackup, TTL 10m (can hang on an absent disk)
#   power    system_profiler SPPowerDataType, TTL 60m, only on Macs with a battery
# macstat.py has no machine-readable mode, so its plain text is parsed. If the
# parse fails or the cache is not there yet, ps stands in for the top lists.

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'

# SwiftBar starts plugins with a minimal PATH.
ENV['PATH'] = [ENV['PATH'], '/usr/bin', '/bin', '/usr/sbin', '/sbin'].compact.join(':')

require_relative '../lib/menu_kit'

module MacHealth
  GIB = 1 << 30

  GREEN = '#2e9d4f,#4ade80'
  AMBER = '#d98e04,#fbbf24'
  RED = '#d93a2f,#f87171'
  MUTED = '#8e8e93,#98989d'

  COLORS = { ok: GREEN, warn: AMBER, crit: RED, info: MUTED, na: MUTED }.freeze
  SYMBOLS = { ok: '●', warn: '▲', crit: '■', info: '○', na: '○' }.freeze
  RANK = { crit: 2, warn: 1 }.freeze

  DISK_AMBER_BELOW = 15 # free % of the data volume
  DISK_RED_BELOW = 8
  SWAP_AMBER = 2 * GIB
  SWAP_RED = 4 * GIB
  LOAD_AMBER = 1.0 # 5-minute load per core
  LOAD_RED = 2.0
  BATTERY_AMBER = 35
  BATTERY_RED = 20
  HEALTH_AMBER = 80 # maximum capacity %
  BACKUP_AMBER_DAYS = 7
  BACKUP_RED_DAYS = 30
  UPTIME_NOTE_DAYS = 14

  PYTHON = '/usr/bin/python3'
  MACSTAT = File.expand_path('../bin/macstat.py', __dir__)

  # Dev folders that tend to grow. A short fixed list, never a full scan, and
  # none of the protected personal folders. Folders that don't exist are
  # skipped. QUIETBAR_SIZE_PATHS (colon-separated) replaces the list.
  SIZE_PATHS = (ENV['QUIETBAR_SIZE_PATHS'] ? ENV['QUIETBAR_SIZE_PATHS'].split(':') : %w[
    ~/Library/Caches ~/.gradle ~/.android ~/Library/Application\ Support/Herd
    ~/.npm ~/.claude ~/.composer ~/.m2 ~/.cache
    ~/Library/Developer/Xcode/DerivedData ~/Library/Developer/CoreSimulator
    ~/Library/Containers/com.docker.docker
  ]).freeze
  SIZE_MIN_KB = 200 * 1024
  SIZES_BUDGET = 70 # seconds for the whole du pass

  TTL = { 'macstat' => 90, 'sizes' => 1800, 'backup' => 600, 'power' => 3600 }.freeze

  module Shell
    module_function

    def utf8(text)
      text.to_s.dup.force_encoding('UTF-8').scrub('?')
    end

    # [stdout, stderr, status]. A command past its timeout is killed.
    def run(*args, timeout: 5, env: {})
      out = err = status = nil
      Open3.popen3(env, *args) do |stdin, stdout, stderr, wait|
        stdin.close
        o = Thread.new { stdout.read }
        e = Thread.new { stderr.read }
        unless wait.join(timeout)
          begin
            Process.kill('KILL', wait.pid)
          rescue SystemCallError
            nil
          end
          raise Timeout::Error, "#{args.first} timed out"
        end
        out = o.value
        err = e.value
        status = wait.value
      end
      [utf8(out), utf8(err), status]
    end

    def out(*args, **opts)
      out, err, status = run(*args, **opts)
      unless status.success?
        raise "#{args.first} failed: #{(err.empty? ? out : err).lines.first.to_s.strip}"
      end

      out
    end
  end

  # Slow probes. These only run in the detached copy of the script.
  module Work
    module_function

    def macstat
      out, err, status = Shell.run(PYTHON, MACSTAT, timeout: 25,
                                                   env: { 'PYTHONIOENCODING' => 'utf-8' })
      raise "macstat failed: #{err.lines.first.to_s.strip}" unless status.success?

      out.gsub(/\e\[[0-9;]*m/, '')
    end

    def sizes
      deadline = Time.now + SIZES_BUDGET
      SIZE_PATHS.each_with_object({}) do |raw, memo|
        path = File.expand_path(raw)
        next unless File.directory?(path)

        left = deadline - Time.now
        break if left <= 0

        memo[path] = du(path, [left, 25].min, children: path.end_with?('/Library/Caches'))
      end
    end

    # du exits non-zero on the odd protected subfolder but still prints sizes.
    def du(path, timeout, children: false)
      flags = children ? %w[-k -d 1] : %w[-sk]
      out, = Shell.run('du', *flags, path, timeout: timeout)
      rows = out.lines.map { |l| l.chomp.split("\t", 2) }.select { |kb, _| kb =~ /\A\d+\z/ }
      total = rows.find { |_, p| p == path }&.first || rows.last&.first
      return nil unless total

      entry = { 'kb' => total.to_i }
      if children
        kids = rows.reject { |_, p| p == path }.map { |kb, p| [File.basename(p), kb.to_i] }
        entry['children'] = kids.sort_by { |_, kb| -kb }.first(6)
      end
      entry
    rescue Timeout::Error
      nil
    end

    def backup
      out, err, status = Shell.run('tmutil', 'latestbackup', timeout: 20)
      unless status.success?
        raise((err.empty? ? out : err).lines.first.to_s.strip.then { |m| m.empty? ? 'tmutil failed' : m })
      end

      out.strip
    end

    def power
      out = Shell.out('system_profiler', 'SPPowerDataType', timeout: 40)
      {
        'cycles' => out[/Cycle Count:\s*(\d+)/, 1]&.to_i,
        'condition' => out[/Condition:\s*(.+)/, 1]&.strip,
        'capacity' => out[/Maximum Capacity:\s*(\d+)/, 1]&.to_i
      }
    end
  end

  class Cache
    DIR = File.expand_path('~/.cache/swiftbar-mac-health')
    LOCK_STALE = 120

    def self.path(name)
      File.join(DIR, "#{name}.json")
    end

    # Entry { 'at', 'data', 'error' } or nil. Starts a background refresh when
    # the entry is missing or older than ttl; the caller uses what is there.
    def self.fetch(name)
      entry = begin
        JSON.parse(File.read(path(name)))
      rescue StandardError
        nil
      end
      spawn_refresh(name) if entry.nil? || Time.now.to_i - entry['at'].to_i > TTL.fetch(name)
      entry
    end

    def self.spawn_refresh(name)
      FileUtils.mkdir_p(DIR)
      return unless lock(name)

      pid = Process.spawn(RbConfig.ruby, File.expand_path(__FILE__), 'refresh', name,
                          in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
      Process.detach(pid)
    rescue SystemCallError
      nil
    end

    def self.lock(name, again: true)
      File.open("#{path(name)}.lock", File::WRONLY | File::CREAT | File::EXCL) {}
      true
    rescue Errno::EEXIST
      stale = begin
        Time.now - File.mtime("#{path(name)}.lock") > LOCK_STALE
      rescue SystemCallError
        true
      end
      return false unless stale && again

      File.delete("#{path(name)}.lock") rescue nil # rubocop:disable Style/RescueModifier
      lock(name, again: false)
    end

    # Runs in the detached copy: produce, write atomically, drop the lock.
    def self.refresh(name)
      return unless TTL.key?(name)

      begin
        write(name, Work.public_send(name), nil)
      rescue StandardError => e
        write(name, nil, e.message.lines.first.to_s.strip)
      end
    ensure
      File.delete("#{path(name)}.lock") rescue nil # rubocop:disable Style/RescueModifier
    end

    def self.write(name, data, error)
      tmp = "#{path(name)}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate('at' => Time.now.to_i, 'data' => data, 'error' => error))
      File.rename(tmp, path(name))
    end
  end

  class Monitor

    def run
      @snapshot = parse_snapshot
      @disk = safe { disk }
      @mem = safe { memory }
      @cpu = safe { cpu }
      @battery = safe { battery }
      @backup = safe { backup }
      @uptime = safe { uptime }

      level, label = headline
      printer.item(label, dropdown: false, color: COLORS[level])
      print_disk
      print_memory
      print_cpu
      print_battery
      print_backup
      print_uptime
      footer
    end

    private

    def printer
      @printer ||= MenuKit::Printer.new
    end

    # A failing probe becomes nil and its rows show n/a.
    def safe
      yield
    rescue StandardError, ScriptError
      nil
    end

    # --- probes ---------------------------------------------------------------

    def sysctl(key)
      Shell.out('sysctl', '-n', key).strip
    end

    def disk
      row = Shell.out('df', '-k', '/System/Volumes/Data').lines[1].split
      size = row[1].to_i * 1024
      avail = row[3].to_i * 1024
      raise 'df gave no size' unless size.positive?

      free = avail * 100.0 / size
      level = if free < DISK_RED_BELOW then :crit
              elsif free < DISK_AMBER_BELOW then :warn
              else :ok
              end
      { size: size, avail: avail, free: free, level: level, sizes: Cache.fetch('sizes') }
    end

    def memory
      pressure = safe { sysctl('kern.memorystatus_vm_pressure_level').to_i }
      ram = safe { sysctl('hw.memsize').to_i }
      swap = safe do
        used = Shell.out('sysctl', '-n', 'vm.swapusage')
        mb = ->(k) { used[/#{k} = ([\d.]+)M/, 1].to_f * 1024 * 1024 }
        [mb.call('used'), mb.call('total')]
      end
      return if pressure.nil? && ram.nil? && swap.nil?

      used = @snapshot&.fetch(:used, nil)
      used = safe { activity_monitor_used } if used.nil?

      level = case pressure
              when nil then :na
              when 1 then :ok
              when 2 then :warn
              else :crit
              end
      if swap
        level = worse(level, :crit) if swap[0] >= SWAP_RED
        level = worse(level, :warn) if swap[0] >= SWAP_AMBER
      end
      apps = @snapshot && @snapshot[:mem_apps]
      { pressure: pressure, ram: ram, used: used, swap: swap, level: level,
        apps: apps.nil? || apps.empty? ? ps_top[:mem] : apps }
    end

    # Memory used as Activity Monitor adds it up, same as macstat.py: app (anonymous pages less
    # purgeable) + wired + compressed. Not total minus free, which counts cached files as used.
    def activity_monitor_used
      vm = Shell.out('vm_stat')
      page = vm[/page size of (\d+) bytes/, 1].to_i
      pages = ->(label) { vm[/^#{label}:\s+(\d+)/, 1].to_i }
      app = [sysctl('vm.page_pageable_internal_count').to_i - pages.call('Pages purgeable'), 0].max
      (app + pages.call('Pages wired down') + pages.call('Pages occupied by compressor')) * page
    end

    def cpu
      load = sysctl('vm.loadavg').scan(/[\d.]+/).map(&:to_f)
      cores = sysctl('hw.ncpu').to_i
      raise 'no load average' if load.size < 3 || cores < 1

      per_core = load[1] / cores
      level = if per_core >= LOAD_RED then :crit
              elsif per_core >= LOAD_AMBER then :warn
              else :ok
              end
      apps = @snapshot && @snapshot[:cpu_apps]
      apps = nil if apps && apps.empty?
      { load: load, cores: cores, level: level, per_core: per_core,
        user: @snapshot&.fetch(:user, nil), sys: @snapshot&.fetch(:sys, nil),
        apps: apps || ps_top[:cpu], by_energy: !apps.nil? }
    end

    def battery
      out = Shell.out('pmset', '-g', 'batt')
      source = out[/drawing from '(.+?)'/, 1]
      m = out.match(/(\d+)%;\s*([^;]+);/)
      return { present: false, source: source, level: :info } unless m

      pct = m[1].to_i
      state = m[2].strip
      plugged = source.to_s.include?('AC')
      level = :ok
      unless plugged
        level = pct < BATTERY_RED ? :crit : (pct < BATTERY_AMBER ? :warn : :ok)
      end
      power = Cache.fetch('power')
      health = power && power['data']
      level = worse(level, :warn) if health && health['capacity'] && health['capacity'] < HEALTH_AMBER
      { present: true, pct: pct, state: state, plugged: plugged, level: level,
        remaining: out[/;\s*(\d+:\d+) remaining/, 1], health: health,
        health_pending: power.nil? }
    end

    def backup
      out, err, status = Shell.run('tmutil', 'destinationinfo', timeout: 5)
      text = "#{out}#{err}"
      return { state: :none, level: :info } if text.include?('No destinations configured')
      unless status.success?
        return { state: :error, level: :na, msg: text.lines.first.to_s.strip }
      end

      name = out[/^Name\s*:\s*(.+)/, 1]
      entry = Cache.fetch('backup')
      return { state: :pending, level: :info, name: name } unless entry
      return { state: :error, level: :na, name: name, msg: entry['error'] } if entry['error']

      stamp = entry['data'].to_s[/(\d{4})-(\d\d)-(\d\d)-(\d\d)(\d\d)(\d\d)/]
      return { state: :never, level: :warn, name: name } unless stamp

      parts = stamp.split('-').map(&:to_i)
      time = Time.local(parts[0], parts[1], parts[2], parts[3] / 10_000, parts[3] / 100 % 100, parts[3] % 100)
      age = Time.now - time
      level = if age > BACKUP_RED_DAYS * 86_400 then :crit
              elsif age > BACKUP_AMBER_DAYS * 86_400 then :warn
              else :ok
              end
      { state: :ok, level: level, name: name, age: age, at: time }
    end

    def uptime
      boot = sysctl('kern.boottime')[/sec = (\d+)/, 1].to_i
      raise 'no boot time' if boot.zero?

      secs = Time.now.to_i - boot
      { secs: secs, level: :info }
    end

    # --- macstat.py ------------------------------------------------------------

    # Reads the cached plain-text snapshot. Nil when it is missing or its layout
    # no longer matches, so the caller falls back to ps.
    def parse_snapshot
      entry = Cache.fetch('macstat')
      text = entry && entry['data']
      return unless text.is_a?(String)

      snap = { mem_apps: [], cpu_apps: [], at: entry['at'] }
      text.each_line do |line|
        if (m = line.match(%r{\bMEM\s+\S\s+\w+ · ([\d.]+)/([\d.]+) GB}))
          snap[:used] = m[1].to_f * GIB
        end
        if (m = line.match(/\bCPU\s+load [\d.]+\/\d+ · user (\d+)% sys (\d+)%/))
          snap[:user] = m[1].to_i
          snap[:sys] = m[2].to_i
        end
        left = line.match(/\A(.+?)\s+[█░]{14}\s+([\d.]+) (GB|MB)\s+(\d+)%/)
        next unless left

        bytes = left[2].to_f * (left[3] == 'GB' ? GIB : 1 << 20)
        snap[:mem_apps] << [left[1].strip, bytes, left[4].to_i]
        right = left.post_match.match(/\s+(.+?)\s+[█░]{14}\s+([\d.]+)\s+(\d+)%/)
        snap[:cpu_apps] << [right[1].strip, right[3].to_i, right[2].to_f] if right
      end
      # The energy table can be longer than the memory table.
      text.each_line do |line|
        next if line =~ /\A.+?\s+[█░]{14}\s+[\d.]+ (GB|MB)/

        right = line.match(/\A\s*(.+?)\s+[█░]{14}\s+([\d.]+)\s+(\d+)%/)
        snap[:cpu_apps] << [right[1].strip, right[3].to_i, right[2].to_f] if right
      end
      return if snap[:used].nil? && snap[:mem_apps].empty?

      snap
    end

    # Cheap stand-in for macstat's top lists: ps, summed per process name.
    def ps_top
      @ps_top ||= begin
        by_name = Hash.new { |h, k| h[k] = [0, 0.0] }
        Shell.out('ps', '-Aceo', 'rss=,pcpu=,comm=').each_line do |line|
          rss, pcpu, name = line.strip.split(/\s+/, 3)
          next unless name

          by_name[name][0] += rss.to_i * 1024
          by_name[name][1] += pcpu.to_f
        end
        ram = safe { sysctl('hw.memsize').to_i }.to_i
        {
          mem: by_name.sort_by { |_, v| -v[0] }.first(3)
                      .map { |n, v| [n, v[0], ram.positive? ? (v[0] * 100.0 / ram).round : 0] },
          cpu: by_name.sort_by { |_, v| -v[1] }.first(3).map { |n, v| [n, v[1].round, nil] }
        }
      end
    rescue StandardError
      { mem: nil, cpu: nil }
    end

    # --- title -----------------------------------------------------------------

    def worse(a, b)
      RANK.fetch(a, 0) >= RANK.fetch(b, 0) ? a : b
    end

    # The worst section names itself in the title; with nothing wrong it is
    # the battery when unplugged, else the free disk space.
    def headline
      candidates = [
        [@disk, @disk && "#{(@disk[:avail] / GIB.to_f).round}G"],
        [@mem, @mem && memory_short],
        [@battery, @battery && @battery[:present] && "#{@battery[:pct]}%"],
        [@backup, @backup && @backup[:age] && "bkp #{(@backup[:age] / 86_400).floor}d"],
        [@cpu, @cpu && "load #{@cpu[:load][1].round(1)}"]
      ].select { |data, text| data && text && RANK.key?(data[:level]) }

      worst = candidates.max_by { |data, _| RANK[data[:level]] }
      return [worst[0][:level], "◉ #{worst[1]}"] if worst

      if @battery && @battery[:present] && !@battery[:plugged]
        [:ok, "◉ #{@battery[:pct]}%"]
      elsif @disk
        [:ok, "◉ #{(@disk[:avail] / GIB.to_f).round}G"]
      else
        [:na, '◉ n/a']
      end
    end

    def memory_short
      swap_heavy = @mem[:swap] && @mem[:swap][0] >= SWAP_AMBER
      return "swap #{fmt_bytes(@mem[:swap][0])}" if swap_heavy && @mem[:pressure] == 1

      "mem #{{ 2 => 'warn', 4 => 'crit' }.fetch(@mem[:pressure], 'warn')}"
    end

    # --- rendering ---------------------------------------------------------------

    def fmt_bytes(bytes)
      bytes >= GIB ? format('%.1f GB', bytes / GIB.to_f) : "#{(bytes / (1 << 20).to_f).round} MB"
    end

    def fmt_age(secs)
      secs = secs.to_i
      days = secs / 86_400
      return "#{days}d #{secs % 86_400 / 3600}h" if days.positive?
      return "#{secs / 3600}h #{secs % 3600 / 60}m" if secs >= 3600

      "#{secs / 60}m"
    end

    def bar(pct, width = 20)
      filled = (pct / 100.0 * width).round.clamp(0, width)
      ('█' * filled) + ('░' * (width - filled))
    end

    def clean(text)
      text.to_s.tr('|', '¦')
    end

    def meter(label, pct, text, level)
      printer.item("#{label.ljust(7)} #{bar(pct)}  #{clean(text)}",
                   font: 'Menlo', color: COLORS[level])
    end

    def na(label)
      printer.sep
      printer.item("#{label.ljust(7)} n/a", font: 'Menlo', color: MUTED)
    end

    def open_item(prn, label, path)
      prn.item(label, shell: ['/usr/bin/open', path], terminal: false)
    end

    def tilde(path)
      path.sub(Dir.home, '~')
    end

    def print_disk
      return na('Disk') unless @disk

      printer.sep
      d = @disk
      used = 100 - d[:free]
      meter('Disk', used, "#{used.round}% used", d[:level])
      printer.item("#{fmt_bytes(d[:avail])} free of #{fmt_bytes(d[:size])} (data volume)")
      print_sizes(d[:sizes])
    end

    def print_sizes(entry)
      if entry.nil?
        printer.item('Biggest folders: measuring, shows on the next refresh', color: MUTED)
        return
      end
      sizes = entry['data']
      if entry['error'] || !sizes.is_a?(Hash)
        printer.item('Biggest folders: n/a', color: MUTED)
        return
      end

      rows = sizes.map { |path, v| [path, v] }.select { |_, v| v && v['kb'] >= SIZE_MIN_KB }
                  .sort_by { |_, v| -v['kb'] }.first(5)
      if rows.empty?
        printer.item('No big dev folders', color: MUTED)
        return
      end

      ago = fmt_age(Time.now.to_i - entry['at'].to_i)
      printer.item("Biggest folders (as of #{ago} ago)", color: MUTED)
      rows.each do |path, v|
        label = "#{tilde(path)}  #{fmt_bytes(v['kb'] * 1024)}"
        if v['children']
          printer.item(label, shell: ['/usr/bin/open', path], terminal: false) do |sub|
            v['children'].each do |name, kb|
              open_item(sub, "#{name}  #{fmt_bytes(kb * 1024)}", File.join(path, name))
            end
          end
        else
          open_item(printer, label, path)
        end
      end
    end

    def print_memory
      return na('Memory') unless @mem

      printer.sep
      m = @mem
      name = { 1 => 'normal', 2 => 'warning', 4 => 'critical' }.fetch(m[:pressure], 'unknown')
      if m[:used] && m[:ram]
        meter('Memory', m[:used] * 100.0 / m[:ram],
              "#{fmt_bytes(m[:used])} of #{fmt_bytes(m[:ram])} · pressure #{name}", m[:level])
      else
        printer.item("Memory  pressure #{name}", font: 'Menlo', color: COLORS[m[:level]])
      end
      if m[:swap]
        used, total = m[:swap]
        swap_level = if used >= SWAP_RED then :crit
                     elsif used >= SWAP_AMBER then :warn
                     else :ok
                     end
        pct = total.positive? ? used * 100.0 / total : 0
        meter('Swap', pct, "#{fmt_bytes(used)} of #{fmt_bytes(total)}", swap_level)
      end
      print_top('Top memory', m[:apps]) { |_, bytes, pct| "#{fmt_bytes(bytes)} (#{pct}%)" }
    end

    def print_cpu
      return na('CPU') unless @cpu

      printer.sep
      c = @cpu
      meter('CPU', [c[:per_core] * 100, 100].min,
            "load #{c[:load][1].round(1)} of #{c[:cores]} cores (5 min)", c[:level])
      extra = c[:user] ? " · user #{c[:user]}% sys #{c[:sys]}%" : ''
      printer.item("Load #{c[:load].map { |l| format('%.2f', l) }.join(' ')}#{extra}")
      title = c[:by_energy] ? 'Top by energy impact' : 'Top by CPU'
      print_top(title, c[:apps]) do |_, cpu, impact|
        impact ? "impact #{impact} · #{cpu}% cpu" : "#{cpu}% cpu"
      end
    end

    def print_top(title, apps)
      return printer.item("#{title}: n/a", color: MUTED) if apps.nil? || apps.empty?

      printer.item(title, color: MUTED)
      apps.first(3).each do |app|
        printer.item("#{clean(app[0])}  #{yield(*app)}")
      end
    end

    def print_battery
      b = @battery
      return na('Battery') unless b

      printer.sep
      unless b[:present]
        printer.item("Battery  none (#{b[:source] || 'desktop Mac'})", font: 'Menlo', color: MUTED)
        return
      end

      state = b[:state]
      state += ", #{b[:remaining]} left" if b[:remaining] && !b[:plugged]
      meter('Battery', b[:pct], "#{b[:pct]}% · #{state}", b[:level])
      h = b[:health]
      if h
        parts = []
        parts << "#{h['cycles']} cycles" if h['cycles']
        parts << "health #{h['capacity']}%" if h['capacity']
        parts << h['condition'] if h['condition']
        printer.item(parts.join(' · ')) unless parts.empty?
      elsif b[:health_pending]
        printer.item('Cycles and health: measuring, shows on the next refresh', color: MUTED)
      end
    end

    def print_backup
      b = @backup
      return na('Backup') unless b

      printer.sep
      name = b[:name] ? " (#{clean(b[:name])})" : ''
      case b[:state]
      when :none
        printer.item('Backup  Time Machine not configured', font: 'Menlo', color: MUTED)
      when :pending
        printer.item("Backup  checking#{name}", font: 'Menlo', color: MUTED)
      when :error
        printer.item("Backup  n/a#{name}", font: 'Menlo', color: MUTED)
        printer.item(clean(b[:msg]), color: MUTED) if b[:msg] && !b[:msg].empty?
      when :never
        printer.item("Backup  no backup yet#{name}", font: 'Menlo', color: COLORS[b[:level]])
      else
        printer.item("Backup  last #{fmt_age(b[:age])} ago#{name}", font: 'Menlo', color: COLORS[b[:level]])
        printer.item("#{b[:at].strftime('%a %-d %b %H:%M')}, flagged after #{BACKUP_AMBER_DAYS} days")
      end
    end

    def print_uptime
      u = @uptime
      return na('Uptime') unless u

      printer.sep
      days = u[:secs] / 86_400
      printer.item("Uptime  #{fmt_age(u[:secs])}", font: 'Menlo')
      return if days < UPTIME_NOTE_DAYS

      printer.item("Up #{days} days, consider a restart", color: AMBER)
    end

    def footer
      printer.sep
      printer.item('⏳ Refresh', alt: '⏳ Refresh (⌘R)', refresh: true)
      printer.item('Open Activity Monitor', shell: ['/usr/bin/open', '-a', 'Activity Monitor'],
                                           terminal: false)
      printer.item('Open Storage settings',
                   href: 'x-apple.systempreferences:com.apple.settings.Storage')
    end
  end
end

begin
  if ARGV[0] == 'refresh'
    MacHealth::Cache.refresh(ARGV[1].to_s)
  else
    MacHealth::Monitor.new.run
  end
rescue StandardError, ScriptError => e
  puts '—'
  puts '---'
  puts "Error: #{e.message.lines.first.to_s.strip.tr('|', '¦')}"
  exit 0
end
