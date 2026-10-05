#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Ports</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.desc>What is listening on TCP ports, who owns it, stop it; find what holds a folder open</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>

require 'open3'
require 'timeout'

require_relative '../lib/menu_kit'

# Ports lists listening TCP ports with their owning process, and finds what
# holds a folder open.
module Ports
  # One row. Processes that share the same sockets (nginx workers, IPv4 + IPv6)
  # are merged into the lowest pid, the others are kept in `others`.
  Listener = Struct.new(:pid, :ppid, :uid, :etime, :exe, :args, :name, :ports,
                        :binds, :cwd, :label, :others, keyword_init: true) do
    def launchd?
      !label.nil?
    end
  end

  # A process holding a folder open, with how.
  Holder = Struct.new(:pid, :name, :uid, :cwd, :execs, :files, keyword_init: true)

  class Listeners
    include MenuKit::Commands

    PREFIX = '⇄'
    TITLE = 'What is holding this folder?'
    SCAN_LIMIT = 20 # seconds for lsof +D, which walks the whole tree

    # Executables of macOS itself. Anything else running as the user is listed
    # as the user's own, third-party apps included.
    SYSTEM_PATH = %r{\A/(System|usr/libexec|usr/sbin|sbin|Library/Apple)/}.freeze
    HINTS = {
      'ControlCenter' => 'AirPlay Receiver',
      'rapportd' => 'Continuity / Handoff',
      'sharingd' => 'Sharing',
      'identityservicesd' => 'iMessage / FaceTime'
    }.freeze
    GENERIC_SCRIPTS = %w[index server app main cli start dev serve].freeze

    def run
      rows = listeners
      mine, other = rows.partition { |row| own?(row) }
      mine.sort_by! { |row| row.ports.min }
      other.sort_by! { |row| row.ports.min }

      printer.item("#{PREFIX}#{mine.flat_map(&:ports).uniq.size}", dropdown: false)
      printer.sep
      printer.item('⏳ Refresh', alt: '⏳ Refresh (⌘R)', refresh: true)

      printer.sep
      if mine.empty?
        printer.item('Nothing of yours is listening')
      else
        printer.item("Listening (#{mine.size}):")
        mine.each { |row| print_listener(printer, row) }
      end

      unless other.empty?
        printer.sep
        printer.item("System / other (#{other.size})") do |printer|
          other.each { |row| print_system(printer, row) }
        end
      end

      printer.sep
      printer.item("Find what's holding a folder…", rpc: ['find_holder'])
    end

    # RPC methods, called through the menu items or from a shell.
    def copy(*args)
      IO.popen('pbcopy', 'w') { |io| io.print(args.join(' ')) }
    end

    def open_cwd(*args)
      dir = cwds(args.map(&:to_i))[args.first.to_i]
      cmd('open', dir) if dir
    end

    # Non-GUI core of find_holder: prints what holds the folder.
    def holders(folder = nil)
      raise 'usage: holders FOLDER' if folder.nil?

      folder = File.realpath(File.expand_path(folder))
      found, complete = scan_folder(folder)
      puts report(folder, found, complete)
    end

    # Folder picker, scan, dialog, and stopping. Skips the picker when given a
    # folder. PORTS_DIALOG_GIVE_UP=<seconds> makes the dialogs close by
    # themselves.
    def find_holder(folder = nil)
      folder ||= pick_folder
      return if folder.nil? || folder.empty?

      folder = File.realpath(File.expand_path(folder))
      found, complete = scan_folder(folder)
      if found.empty?
        text = if complete
                 'Nothing is holding it. Safe to move.'
               else
                 'Nothing is holding it at the top level, but the deep scan timed out.'
               end
        dialog("#{folder}\n\n#{text}", ['OK'], 'OK')
        return
      end

      mine = found.select { |h| h.uid == uid }
      text = report(folder, found, complete)
      if mine.size < found.size
        text += "\n\nNot yours, can't be stopped from here: #{(found - mine).map(&:name).uniq.join(', ')}"
      end
      return dialog(text, ['OK'], 'OK') if mine.empty?
      return unless dialog(text, ['Cancel', 'Stop them'], 'Cancel') == 'Stop them'

      stopped = mine.map { |h| stop_pid(h.pid) }
      sleep 1.5
      left, = scan_folder(folder)
      msg = if left.empty?
              "Stopped #{stopped.size}. Nothing holds #{File.basename(folder)} now."
            else
              "Still held by: #{left.map { |h| "#{h.name} (#{h.pid})" }.join(', ')}"
            end
      osa(['on run argv', 'display notification (item 1 of argv) with title "Ports"', 'end run'], msg)
      system('open', '-g', "swiftbar://refreshplugin?name=#{plugin_name}")
    end

    private

    def uid
      @uid ||= Process.uid
    end

    def own?(row)
      row.uid == uid && row.exe !~ SYSTEM_PATH
    end

    def print_listener(printer, row)
      icon = row.launchd? ? '⚙️' : '🟢'
      printer.item("#{icon} #{truncate(row_text(row))}") do |printer|
        row.ports.each do |port|
          printer.item("Open http://localhost:#{port}", href: "http://localhost:#{port}")
        end

        if row.launchd?
          printer.item(
            "Stop job (launchctl bootout #{row.label})",
            terminal: false, refresh: true,
            shell: ['/bin/launchctl', 'bootout', "gui/#{uid}/#{row.label}"]
          )
          printer.item(
            'Force kill (SIGKILL, launchd will respawn it)',
            terminal: false, refresh: true,
            shell: ['/bin/kill', '-KILL', row.pid]
          )
        else
          printer.item(
            'Stop (SIGTERM)',
            terminal: false, refresh: true,
            shell: ['/bin/kill', '-TERM', row.pid]
          )
          printer.item(
            'Force kill (SIGKILL)',
            terminal: false, refresh: true,
            shell: ['/bin/kill', '-KILL', row.pid]
          )
        end

        printer.sep
        printer.item('Open folder in Finder', rpc: ['open_cwd', row.pid]) if row.cwd
        printer.item('Copy PID', rpc: ['copy', row.pid])
        row.ports.each do |port|
          label = row.ports.size > 1 ? "Copy port #{port}" : 'Copy port'
          printer.item(label, rpc: ['copy', port])
        end

        printer.sep
        printer.item("PID: #{row.pid}")
        printer.item("Owner: #{row.launchd? ? "launchd #{row.label}" : 'terminal / manual'}")
        printer.item("Uptime: #{uptime(row.etime)}")
        printer.item("Listening on: #{row.binds.join(', ')}")
        printer.item("Folder: #{row.cwd || '<unknown>'}")
        printer.item("Command: #{truncate("#{row.exe} #{row.args}".strip)}")
        unless row.others.empty?
          printer.item("Shared with #{row.others.size} more: #{truncate(row.others.join(' '), 80)}")
        end
      end
    end

    def print_system(printer, row)
      user = row.uid == uid ? nil : user_name(row.uid)
      text = [row_text(row), HINTS[row.name], user].compact.join(' · ')
      printer.item(truncate(text)) do |printer|
        printer.item("Listening on: #{row.binds.join(', ')}")
        printer.item("Command: #{truncate("#{row.exe} #{row.args}".strip)}")
      end
    end

    def user_name(id)
      cmd('id', '-nu', id.to_s).strip
    rescue MenuKit::CommandFailed
      id.to_s
    end

    def row_text(row)
      ports = row.ports.map { |p| ":#{p}" }.join(',')
      [ports, row.name, row.pid, uptime(row.etime)].join(' · ')
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

    #
    # Listening sockets
    #

    def lsof(*args)
      cmd('lsof', '-nP', *args)
    rescue MenuKit::CommandFailed
      '' # lsof exits 1 when nothing matches
    end

    # pid => { name:, ports: [Integer], binds: [String] } from one lsof run.
    def listening_sockets
      pid = nil
      lsof('-iTCP', '-sTCP:LISTEN', '-Fpcn').each_line.each_with_object({}) do |line, memo|
        value = line[1..].to_s.strip
        case line[0]
        when 'p'
          pid = value.to_i
          memo[pid] ||= { name: nil, ports: [], binds: [] }
        when 'c' then memo[pid][:name] = value
        when 'n'
          port = value[/:(\d+)\z/, 1]
          next unless port

          memo[pid][:ports] |= [port.to_i]
          memo[pid][:binds] |= [value]
        end
      end
    end

    def ps_table(field)
      out = cmd('ps', '-axo', "pid=,#{field}")
      out.each_line.each_with_object({}) do |line, memo|
        pid, value = line.strip.split(/\s+/, 2)
        memo[pid.to_i] = value.to_s
      end
    end

    def process_table
      @process_table ||= ps_table('ppid=,uid=,etime=,comm=').each_with_object({}) do |(pid, line), memo|
        ppid, puid, etime, exe = line.split(/\s+/, 4)
        memo[pid] = { ppid: ppid.to_i, uid: puid.to_i, etime: etime, exe: exe.to_s }
      end
    end

    def command_table
      @command_table ||= ps_table('command=')
    end

    def args_of(pid)
      exe = process_table.dig(pid, :exe).to_s
      full = command_table[pid].to_s
      full.start_with?(exe) ? full[exe.length..].to_s.strip : full
    end

    def listeners
      sockets = listening_sockets
      sockets.delete(Process.pid)
      rows = sockets.each_with_object({}) do |(pid, sock), memo|
        info = process_table[pid]
        next unless info

        args = args_of(pid)
        memo[pid] = Listener.new(
          pid: pid, ppid: info[:ppid], uid: info[:uid], etime: info[:etime],
          exe: info[:exe], args: args, ports: sock[:ports].sort,
          binds: sock[:binds].sort, label: nil, others: [], cwd: nil,
          name: display_name(info[:exe], args, sock[:name])
        )
      end

      rows = merge(rows)
      jobs = launchd_jobs
      dirs = cwds(rows.select { |row| row.uid == uid }.map(&:pid))
      rows.each do |row|
        row.label = launchd_label(row.pid, jobs)
        row.cwd = dirs[row.pid]
      end
    end

    # Fold a child into its parent when it listens on a subset of the parent's
    # ports, then fold siblings with the same name and ports (workers).
    def merge(rows)
      root_of = lambda do |row|
        parent = rows[row.ppid]
        parent && (row.ports - parent.ports).empty? ? root_of.call(parent) : row
      end

      groups = rows.values.group_by { |row| root_of.call(row) }
      roots = groups.map do |root, members|
        root.others = (members - [root]).map(&:pid)
        root
      end

      roots.group_by { |row| [row.ppid, row.ports, row.name] }.values.map do |siblings|
        first, *rest = siblings.sort_by(&:pid)
        first.others = (first.others + rest.flat_map { |r| [r.pid] + r.others }).sort
        first
      end
    end

    # Interpreters are named after the script they run.
    def display_name(exe, args, lsof_name)
      base = File.basename(exe)
      tokens = args.split
      script = tokens.reject { |t| t.start_with?('-') }.first
      case base.downcase
      when 'node' then node_name(tokens)
      when /\Apython/
        mod = args[/-m\s+(\S+)/, 1]
        mod ? "python -m #{mod}" : (script ? File.basename(script) : 'python')
      when 'ruby', 'php'
        script ? "#{base} #{File.basename(script)}" : base
      else
        # nginx and friends retitle themselves ("nginx: worker process")
        exe.include?('/') ? base : lsof_name
      end
    end

    def node_name(tokens)
      return 'node -e' if tokens.any? { |t| %w[-e -p --eval --print].include?(t) }

      script = tokens.reject { |t| t.start_with?('-') }.first
      return 'node' if script.nil?

      base = File.basename(script)
      stem = base.sub(/\.[cm]?[jt]s\z/, '')
      if script =~ %r{/node_modules/\.bin/([^/]+)\z}
        Regexp.last_match(1)
      elsif GENERIC_SCRIPTS.include?(stem)
        "#{File.basename(File.dirname(script))}/#{base}"
      else
        base
      end
    end

    def cwds(pids)
      return {} if pids.empty?

      pid = nil
      lsof('-a', '-p', pids.join(','), '-d', 'cwd', '-Fpn')
        .each_line.each_with_object({}) do |line, memo|
        case line[0]
        when 'p' then pid = line[1..].to_i
        when 'n' then memo[pid] = line[1..].strip
        end
      end
    end

    #
    # launchd
    #

    # pid => label for running launchd jobs. System and app jobs are left out
    # so a child of an app is not shown as a job.
    def launchd_jobs
      cmd('launchctl', 'list').each_line.drop(1).each_with_object({}) do |line, memo|
        pid, _status, label = line.strip.split(/\s+/, 3)
        next if pid == '-' || label =~ /\A(com\.apple\.|application\.|0x|\d)/

        memo[pid.to_i] = label
      end
    end

    # The job that owns the process or one of its ancestors.
    def launchd_label(pid, jobs = launchd_jobs)
      6.times do
        return jobs[pid] if jobs[pid]

        pid = process_table.dig(pid, :ppid)
        break if pid.nil? || pid <= 1
      end
      nil
    end

    # Launchd job -> bootout, otherwise SIGTERM. Same logic as the menu items.
    def stop_pid(pid)
      label = launchd_label(pid)
      if label
        cmd('launchctl', 'bootout', "gui/#{uid}/#{label}")
      else
        Process.kill('TERM', pid)
      end
      pid
    rescue MenuKit::CommandFailed, Errno::ESRCH
      pid
    end

    #
    # What holds a folder
    #

    # [holders, complete]. lsof +D walks the whole tree, so it is capped. When
    # that times out, +d (the folder's own level only) is the fallback.
    def scan_folder(folder)
      out = lsof_capped(['+D', folder], SCAN_LIMIT)
      complete = !out.nil?
      out ||= lsof_capped(['+d', folder], 10).to_s
      [parse_holders(out), complete]
    end

    def lsof_capped(args, limit)
      Open3.popen3('lsof', '-nP', *args, '-Fpcufn') do |stdin, stdout, stderr, thread|
        stdin.close
        errors = Thread.new { stderr.read }
        begin
          Timeout.timeout(limit) { stdout.read }
        rescue Timeout::Error
          Process.kill('KILL', thread.pid)
          nil
        ensure
          errors.kill
        end
      end
    end

    def parse_holders(out)
      found = {}
      current = nil
      fd = nil
      out.each_line do |line|
        value = line[1..].to_s.chomp
        case line[0]
        when 'p'
          pid = value.to_i
          current = pid == Process.pid ? nil : (found[pid] ||= Holder.new(pid: pid, execs: [], files: []))
        when 'c' then current&.name = value
        when 'u' then current&.uid = value.to_i
        when 'f' then fd = value
        when 'n'
          next unless current

          if fd == 'cwd'
            current.cwd = value
          elsif %w[txt mem].include?(fd)
            current.execs |= [value]
          elsif fd =~ /\A\d+/
            current.files |= [value]
          end
        end
      end
      found.values.sort_by(&:pid)
    end

    def report(folder, found, complete)
      return 'Nothing is holding it. Safe to move.' if found.empty?

      jobs = launchd_jobs
      lines = found.first(12).map do |h|
        how = []
        how << (h.cwd == folder ? 'cwd' : "cwd in #{rel(h.cwd, folder)}") if h.cwd
        how << 'running from it' unless h.execs.empty?
        unless h.files.empty?
          noun = h.files.size == 1 ? 'open file' : 'open files'
          how << "#{h.files.size} #{noun} (#{rel(h.files.first, folder)})"
        end
        label = launchd_label(h.pid, jobs)
        how << "launchd job #{label}" if label
        "• #{h.name} · PID #{h.pid} · #{how.join(' · ')}"
      end
      lines << "…and #{found.size - 12} more" if found.size > 12

      head = "#{found.size} #{found.size == 1 ? 'process holds' : 'processes hold'} #{folder}"
      head += ' (deep scan timed out, top level only)' unless complete
      "#{head}\n\n#{lines.join("\n")}"
    end

    def rel(path, folder)
      path.delete_prefix("#{folder}/")
    end

    #
    # Dialogs
    #

    # Runs AppleScript lines with argv, so no text needs escaping.
    def osa(lines, *argv)
      out, _err, status = Open3.capture3('osascript', *lines.flat_map { |l| ['-e', l] }, *argv)
      status.success? ? out.strip : nil
    end

    def pick_folder
      default = File.expand_path(ENV['QUIETBAR_PROJECTS_DIR'] || '~/git')
      where = File.directory?(default) ? %( default location (POSIX file "#{default}")) : ''
      osa(['tell current application to activate',
           %(POSIX path of (choose folder with prompt "Which folder won't move?"#{where}))])
    end

    # Returns the label of the clicked button, nil on cancel or give-up.
    def dialog(text, buttons, default)
      give_up = ENV['PORTS_DIALOG_GIVE_UP'].to_i
      clause = give_up.positive? ? " giving up after #{give_up}" : ''
      list = buttons.map { |b| %("#{b}") }.join(', ')
      show = %(display dialog (item 1 of argv) with title "#{TITLE}" buttons {#{list}} ) +
             %(default button "#{default}" cancel button "#{buttons.first}" with icon caution#{clause})
      out = osa(['on run argv', 'tell current application to activate', show, 'end run'], text)
      out && out[/button returned:([^,]*)/, 1]
    end
  end
end

begin
  service = Ports::Listeners.new
  MenuKit.dispatch(service, ARGV)
rescue StandardError => e
  MenuKit.crash(e)
end
