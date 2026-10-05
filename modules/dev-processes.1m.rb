#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Dev Processes</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.desc>List and stop running dev processes (node first) and launchd jobs</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>

require 'open3'

require_relative '../lib/menu_kit'

# Dev lists running dev processes and the user's own launchd jobs.
module Dev
  # A running process worth listing. Ports and cwd are filled in afterwards.
  Entry = Struct.new(:pid, :ppid, :etime, :exe, :args, :kind, :ports, :cwd,
                    :label, keyword_init: true) do
    def node?
      kind == :node
    end

    def launchd?
      !label.nil?
    end
  end

  Agent = Struct.new(:label, :plist, :loaded, :pid, keyword_init: true) do
    def running?
      !pid.nil?
    end
  end

  class Processes
    include MenuKit::Commands

    PREFIX = '⬢'

    AGENT_DIR = File.expand_path('~/Library/LaunchAgents')
    # launchd labels that start with this are yours (QUIETBAR_LABEL_PREFIX)
    AGENT_PREFIX = ENV['QUIETBAR_LABEL_PREFIX'] || 'local.quietbar'
    GENERIC_SCRIPTS = %w[index server app main cli start dev serve].freeze
    PACKAGE_RUNNERS = %w[npm npx pnpm yarn].freeze

    # Only dev servers, so PHP-FPM and other plumbing never shows up.
    PYTHON_SERVER = /-m\s+(http\.server|flask|uvicorn|gunicorn)|runserver|uvicorn|gunicorn/.freeze
    PHP_SERVER = /artisan\s+serve|\s-S\s/.freeze
    RUBY_SERVER = /\b(rails|puma|jekyll|rackup|webrick)\b|bin\/dev/.freeze

    def run
      procs = dev_processes
      nodes = procs.select(&:node?)
      others = procs.reject(&:node?)

      printer.item("#{PREFIX}#{nodes.size}", dropdown: false)
      printer.sep
      printer.item('⏳ Refresh', alt: '⏳ Refresh (⌘R)', refresh: true)

      printer.sep
      if nodes.empty?
        printer.item('No node processes')
      else
        printer.item("Node (#{nodes.size}):")
        nodes.each { |proc| print_process(printer, proc) }
      end

      unless others.empty?
        printer.sep
        printer.item("Other dev servers (#{others.size}):")
        others.each { |proc| print_process(printer, proc) }
      end

      print_agents(printer)
    end

    # RPC methods, called through the menu items.
    def copy(*args)
      IO.popen('pbcopy', 'w') { |io| io.print(args.join(' ')) }
    end

    def open_cwd(*args)
      dir = cwds(args.map(&:to_i))[args.first.to_i]
      cmd('open', dir) if dir
    end

    private

    def uid
      @uid ||= Process.uid
    end

    def print_process(printer, proc)
      icon = proc.launchd? ? '⚙️' : '🟢'
      parts = [short_name(proc)]
      parts << proc.ports.map { |p| ":#{p}" }.join(' ') unless proc.ports.empty?
      parts << uptime(proc.etime)

      printer.item("#{icon} #{truncate(parts.join(' · '))}") do |printer|
        if proc.launchd?
          printer.item(
            "Stop job (launchctl bootout #{proc.label})",
            terminal: false, refresh: true,
            shell: ['/bin/launchctl', 'bootout', "gui/#{uid}/#{proc.label}"]
          )
          printer.item(
            'Force kill (SIGKILL, launchd will respawn it)',
            terminal: false, refresh: true,
            shell: ['/bin/kill', '-KILL', proc.pid]
          )
        else
          printer.item(
            'Stop (SIGTERM)',
            terminal: false, refresh: true,
            shell: ['/bin/kill', '-TERM', proc.pid]
          )
          printer.item(
            'Force kill (SIGKILL)',
            terminal: false, refresh: true,
            shell: ['/bin/kill', '-KILL', proc.pid]
          )
        end

        printer.sep
        proc.ports.each do |port|
          printer.item("Open http://localhost:#{port}",
                       href: "http://localhost:#{port}")
        end
        if proc.cwd
          printer.item('Open folder in Finder', rpc: ['open_cwd', proc.pid])
        end
        printer.item('Copy PID', rpc: ['copy', proc.pid])

        printer.sep
        printer.item("PID: #{proc.pid}")
        printer.item("Owner: #{proc.launchd? ? "launchd #{proc.label}" : 'terminal / manual'}")
        printer.item("Uptime: #{uptime(proc.etime)}")
        printer.item("Folder: #{proc.cwd || '<unknown>'}")
        printer.item("Command: #{truncate("#{proc.exe} #{proc.args}".strip)}")
      end
    end

    def print_agents(printer)
      agents = launch_agents
      return if agents.empty?

      running = agents.count(&:running?)
      idle = agents.count { |a| a.loaded && !a.running? }
      not_loaded = agents.count { |a| !a.loaded }

      printer.sep
      printer.item(
        "LaunchAgents (#{running} running, #{idle} idle, #{not_loaded} not loaded)"
      ) do |printer|
        agents.each { |agent| print_agent(printer, agent) }
      end
    end

    def print_agent(printer, agent)
      icon, status = if agent.running?
                       ['🟢', "PID #{agent.pid}"]
                     elsif agent.loaded
                       ['🟡', 'idle']
                     else
                       ['🔴', 'not loaded']
                     end

      printer.item("#{icon} #{agent.label} (#{status})") do |printer|
        if agent.loaded
          printer.item(
            'Stop (bootout)',
            terminal: false, refresh: true,
            shell: ['/bin/launchctl', 'bootout', "gui/#{uid}/#{agent.label}"]
          )
        else
          printer.item(
            'Start (bootstrap)',
            terminal: false, refresh: true,
            shell: ['/bin/launchctl', 'bootstrap', "gui/#{uid}", agent.plist]
          )
        end
        printer.item("Plist: #{agent.plist}")
      end
    end

    def truncate(text, max = 140)
      text = text.tr('|', '¦') # a pipe would start SwiftBar's parameters
      text.length > max ? "#{text[0, max - 1]}…" : text
    end

    # ps etime is [[dd-]hh:]mm:ss.
    def uptime(etime)
      days, rest = etime.include?('-') ? etime.split('-', 2) : [0, etime]
      parts = rest.split(':').map(&:to_i)
      hours, minutes, seconds = parts.size == 3 ? parts : [0, *parts]
      days = days.to_i

      return "#{days}d #{hours}h" if days.positive?
      return "#{hours}h #{minutes}m" if hours.positive?
      return "#{minutes}m" if minutes.positive?

      "#{seconds}s"
    end

    def short_name(proc)
      tokens = proc.args.split
      case proc.kind
      when :node then node_name(proc, tokens)
      when :python
        mod = proc.args[/-m\s+(\S+)/, 1]
        mod ? "python -m #{mod}" : "python #{File.basename(non_flags(tokens).first.to_s)}"
      else
        "#{File.basename(proc.exe)} #{non_flags(tokens).first(2).map { |t| File.basename(t) }.join(' ')}".strip
      end
    end

    def non_flags(tokens)
      tokens.reject { |t| t.start_with?('-') }
    end

    # Script path from the args. The path can contain spaces, so tokens are
    # joined until they name an existing file.
    def script_path(proc, tokens)
      tokens = non_flags(tokens)
      return if tokens.empty?

      candidate = ''
      tokens.each do |token|
        candidate = candidate.empty? ? token : "#{candidate} #{token}"
        path = File.expand_path(candidate, proc.cwd || '/')
        return path if File.file?(path)
      end

      tokens.first
    end

    def node_name(proc, tokens)
      return 'node -e' if tokens.any? { |t| %w[-e -p --eval --print].include?(t) }

      script = script_path(proc, tokens)
      return 'node' if script.nil?

      base = File.basename(script)
      stem = base.sub(/\.[cm]?[jt]s\z/, '')

      if script =~ %r{/node_modules/\.bin/([^/]+)\z}
        name = Regexp.last_match(1)
      elsif script =~ %r{/node_modules/((?:@[^/]+/)?[^/]+)/}
        name = Regexp.last_match(1)
      elsif GENERIC_SCRIPTS.include?(stem)
        name = "#{File.basename(File.dirname(script))}/#{base}"
      else
        name = base
      end

      if PACKAGE_RUNNERS.include?(name)
        rest = tokens.drop_while { |t| t.start_with?('-') }.drop(1)
        name = ([name] + non_flags(rest).first(2)).join(' ')
      end

      name
    end

    def ps_table(field)
      out = cmd('ps', '-axo', "pid=,#{field}")
      out.each_line.each_with_object({}) do |line, memo|
        pid, value = line.strip.split(/\s+/, 2)
        memo[pid.to_i] = value.to_s
      end
    end

    def dev_processes
      info = ps_table('ppid=,etime=,comm=')
      full = ps_table('command=')
      jobs = launchd_jobs

      procs = info.each_with_object([]) do |(pid, line), memo|
        next if pid == Process.pid

        ppid, etime, exe = line.split(/\s+/, 3)
        args = full[pid].to_s
        args = args[exe.length..].to_s.strip if args.start_with?(exe)

        kind = kind_of(exe, args)
        next unless kind

        label = jobs[pid] || jobs[ppid.to_i]
        memo << Entry.new(pid: pid, ppid: ppid.to_i, etime: etime, exe: exe,
                         args: args, kind: kind, ports: [], cwd: nil,
                         label: label)
      end

      return procs if procs.empty?

      pids = procs.map(&:pid)
      ports = listening_ports(pids)
      dirs = cwds(pids)
      procs.each do |proc|
        proc.ports = ports.fetch(proc.pid, [])
        proc.cwd = dirs[proc.pid]
      end

      procs.sort_by { |proc| [proc.node? ? 0 : 1, proc.pid] }
    end

    def kind_of(exe, args)
      case File.basename(exe).downcase
      when 'node' then :node
      when /\Apython/ then :python if args =~ PYTHON_SERVER
      when 'php' then :php if args =~ PHP_SERVER
      when 'ruby' then :ruby if args =~ RUBY_SERVER
      end
    end

    def lsof(*args)
      cmd('lsof', '-nP', *args)
    rescue MenuKit::CommandFailed
      '' # lsof exits 1 when nothing matches
    end

    def listening_ports(pids)
      pid = nil
      lsof('-a', '-p', pids.join(','), '-iTCP', '-sTCP:LISTEN', '-Fpn')
        .each_line.each_with_object({}) do |line, memo|
        case line[0]
        when 'p' then pid = line[1..].to_i
        when 'n' then (memo[pid] ||= []) << line.strip[/:(\d+)\z/, 1]
        end
      end.transform_values { |ports| ports.compact.uniq }
    end

    def cwds(pids)
      pid = nil
      lsof('-a', '-p', pids.join(','), '-d', 'cwd', '-Fpn')
        .each_line.each_with_object({}) do |line, memo|
        case line[0]
        when 'p' then pid = line[1..].to_i
        when 'n' then memo[pid] = line[1..].strip
        end
      end
    end

    # pid => label for running launchd jobs. System and app jobs are left out
    # so a node child of an app is not shown as a job.
    def launchd_jobs
      list_launchd.each_with_object({}) do |(label, pid), memo|
        next if pid.nil? || label =~ /\A(com\.apple\.|application\.|0x|\d)/

        memo[pid] = label
      end
    end

    def list_launchd
      cmd('launchctl', 'list').each_line.drop(1).each_with_object({}) do |line, memo|
        pid, _status, label = line.strip.split(/\s+/, 3)
        memo[label] = pid == '-' ? nil : pid.to_i
      end
    end

    def launch_agents
      loaded = list_launchd
      Dir.glob(File.join(AGENT_DIR, "#{AGENT_PREFIX}*.plist")).sort.map do |plist|
        label = File.basename(plist, '.plist')
        Agent.new(label: label, plist: plist, loaded: loaded.key?(label),
                  pid: loaded[label])
      end
    end
  end
end

begin
  service = Dev::Processes.new
  MenuKit.dispatch(service, ARGV)
rescue StandardError => e
  MenuKit.crash(e)
end
