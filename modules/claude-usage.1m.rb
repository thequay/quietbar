#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Claude Usage</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.desc>Claude plan usage (5-hour and weekly) from claude-usage.py</xbar.desc>
# <xbar.dependencies>ruby,python3</xbar.dependencies>
#
# bin/claude-usage.py has no machine-readable mode, so its plain output is
# parsed. It only reads its local cache (~/.cache/claude-usage), written by the
# same script as Claude Code's status line (see README), so running it every
# minute costs nothing and never calls an API. The numbers are as fresh as the
# last Claude response. Until the status line is set up there is no cache, and
# the menu says how to set it up.

require 'open3'
require 'timeout'

require_relative '../lib/menu_kit'

module Claude
  class Unavailable < StandardError; end

  # `resets` is the clock time ("18:00", "Sun 10:00") and `left` the time to it
  # ("2h 55m"); both nil right after a reset. `gone` is only set for the week.
  Window = Struct.new(:pct, :resets, :left, :gone, keyword_init: true)
  Reading = Struct.new(:note, :five, :week, :projection, :gate, :queue,
                       keyword_init: true)

  class Usage

    SCRIPT = File.expand_path('../bin/claude-usage.py', __dir__)
    PYTHON = '/usr/bin/python3'
    ANSI = /\e\[[0-9;]*m/.freeze

    AMBER_FROM = 60
    RED_FROM = 85
    PACE_MARGIN = 5 # points either side of the share of the week gone

    GREEN = '#2e9d4f,#4ade80'
    AMBER = '#d98e04,#fbbf24'
    RED = '#d93a2f,#f87171'
    MUTED = '#8e8e93,#98989d'

    def run
      reading = read
      printer.item(title(reading), dropdown: false, color: color(top(reading)))
      printer.sep
      print_window(printer, '5-hour', reading.five)
      printer.sep
      print_window(printer, 'Week', reading.week)
      print_week_pace(printer, reading.week)
      print_extras(printer, reading)
      footer(printer, reading.note)
    rescue Unavailable, Timeout::Error, SystemCallError => e
      failure(e.is_a?(Timeout::Error) ? 'claude-usage.py timed out' : e.message)
    end

    private

    def printer
      @printer ||= MenuKit::Printer.new
    end

    def failure(reason)
      printer.item('—', dropdown: false, color: MUTED)
      printer.sep
      printer.item('Claude usage unavailable', color: MUTED)
      reason.to_s.lines.map(&:strip).reject(&:empty?).each { |l| printer.item(l.tr('|', '¦')) }
      footer(printer, nil)
    end

    def footer(printer, note)
      printer.sep
      printer.item(note, color: MUTED) if note
      printer.item('⏳ Refresh', alt: '⏳ Refresh (⌘R)', refresh: true)
    end

    def read
      out, err, status = Timeout.timeout(15) { Open3.capture3(PYTHON, SCRIPT) }
      out = out.gsub(ANSI, '')
      unless status.success?
        raise Unavailable, "claude-usage.py failed: #{err.strip.empty? ? "exit #{status.exitstatus}" : err.strip}"
      end

      parse(out)
    end

    def parse(out)
      lines = out.lines.map(&:rstrip)
      head = lines.find { |l| l.start_with?('CLAUDE USAGE') }
      unless head
        raise Unavailable, lines.all?(&:empty?) ? 'no output from claude-usage.py' : lines.join("\n")
      end

      reading = Reading.new(
        note: head.sub('CLAUDE USAGE', '').strip,
        five: window(lines, '5h'),
        week: window(lines, 'week'),
        projection: field(lines, /\AProjection:\s+(.*)/),
        gate: field(lines, /\Agate\s+(.*)/),
        queue: field(lines, /\Aqueue\s+(.*)/)
      )
      raise Unavailable, 'no usage reported yet, it appears after the next Claude response' unless reading.five || reading.week

      reading
    end

    def field(lines, pattern)
      lines.each { |l| m = pattern.match(l) and return m[1].strip }
      nil
    end

    # Rows look like "5h  ██░░░░  10%  resets 18:00 (in 2h 55m)".
    def window(lines, label)
      m = nil
      lines.find { |l| m = /\A#{label}\s+\S+\s+(\d+)%\s+(.*)\z/.match(l) }
      return unless m

      rest = m[2]
      resets = rest[/resets (.+?) \(in /, 1]
      Window.new(pct: m[1].to_i, resets: resets,
                 left: rest[/\(in ([^)]+)\)/, 1],
                 gone: rest[/(\d+)% of week gone/, 1]&.to_i)
    end

    def title(reading)
      parts = []
      parts << "5h #{reading.five.pct}%" if reading.five
      parts << "wk #{reading.week.pct}%" if reading.week
      parts.join(' · ')
    end

    def top(reading)
      [reading.five, reading.week].compact.map(&:pct).max
    end

    def color(pct)
      return RED if pct >= RED_FROM
      return AMBER if pct >= AMBER_FROM

      GREEN
    end

    def bar(pct, width = 20)
      filled = (pct / 100.0 * width).round.clamp(0, width)
      ('█' * filled) + ('░' * (width - filled))
    end

    def print_window(printer, name, win)
      unless win
        printer.item("#{name}: no reading yet", color: MUTED)
        return
      end

      printer.item("#{name.ljust(7)} #{win.pct.to_s.rjust(3)}%  #{bar(win.pct)}",
                   font: 'Menlo', color: color(win.pct))
      if win.resets
        printer.item("Resets #{win.resets} · in #{win.left}")
      else
        printer.item('Reset, nothing used since')
      end
    end

    def print_week_pace(printer, week)
      return unless week&.gone

      diff = week.pct - week.gone
      hint, tone = if diff > PACE_MARGIN
                     ["over pace by #{diff} pts", RED]
                   elsif diff < -PACE_MARGIN
                     ["under pace by #{-diff} pts", GREEN]
                   else
                     ['on pace', nil]
                   end
      props = tone ? { color: tone } : {}
      printer.item("#{week.gone}% of the week gone, #{week.pct}% used: #{hint}",
                   **props)
    end

    def print_extras(printer, reading)
      extras = { 'Projection' => reading.projection, 'Gate' => reading.gate,
                 'Queue' => reading.queue }.reject { |_, v| v.nil? }
      return if extras.empty?

      printer.sep
      extras.each { |k, v| printer.item("#{k}: #{v.tr('|', '¦')}") }
    end
  end
end

begin
  Claude::Usage.new.run
rescue StandardError => e
  puts '—'
  puts '---'
  puts "Error: #{e.message.lines.first.to_s.strip.tr('|', '¦')}"
  exit 0
end
