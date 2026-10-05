# frozen_string_literal: true

# MenuKit: the SwiftBar plumbing the bundled plugins share. Written for this
# repo. A plugin loads it with `require_relative '../lib/menu_kit'`, so it works
# the same in a checkout, once installed, and run by quietbar or by SwiftBar.
#
#   MenuKit::Printer      prints menu lines: label, attributes, nested submenus
#   MenuKit::Commands     mixin for a plugin's main class: `printer` and `cmd`
#   MenuKit.dispatch      runs the plugin's menu (no arguments) or one of its
#                         public methods (`plugin.rb method arg ...`), which is
#                         how a menu line calls back into the plugin
#   MenuKit.crash         what a plugin prints when it falls over

require 'open3'

module MenuKit
  class CommandFailed < StandardError; end
  class UnknownCall < StandardError; end

  module_function

  def swiftbar?
    ENV.fetch('SWIFTBAR', '0') == '1'
  end

  # The plugin SwiftBar believes is running. Under quietbar that is quietbar
  # itself, so a refresh from a plugin's menu reloads the whole bar.
  def plugin_file
    claimed = ENV['SWIFTBAR_PLUGIN_PATH'].to_s
    swiftbar? && !claimed.empty? ? claimed : File.expand_path($PROGRAM_NAME)
  end

  # "ports.1m.rb" -> "ports"
  def plugin_name
    file = File.basename(plugin_file)
    pieces = file.split('.')
    raise "#{file} should be named name.interval.extension" if pieces.length < 3

    pieces[0...-2].join('.')
  end

  def refresh_uri
    return "swiftbar://refreshplugin?name=#{plugin_name}" if swiftbar?

    "xbar://app.xbarapp.com/refreshPlugin?path=#{File.basename(plugin_file)}"
  end

  # Turns what a plugin asks for into the attributes SwiftBar understands.
  #   rpc: [..]     run this plugin again with these arguments
  #   shell: [..]   run this command; its first word is the program
  #   refresh: true reload the plugin after the command ran
  def attributes(asked)
    attrs = asked.dup
    # Without this SwiftBar opens a Terminal window for every command.
    attrs[:terminal] = false if swiftbar? && !attrs.key?(:terminal)

    rpc = attrs.delete(:rpc)
    argv = attrs.delete(:shell)
    argv = [File.expand_path($PROGRAM_NAME), *rpc] if argv.nil? && rpc
    argv = Array(argv)

    # SwiftBar can only refresh through a URL, so a command that wants a
    # refresh gets one chained on. Xbar only manages that in a terminal.
    if attrs[:refresh] && !argv.empty? && (swiftbar? || attrs[:terminal])
      attrs[:refresh] = false
      argv += [';', 'open', '-jg', "'#{refresh_uri}'"]
    end

    unless argv.empty?
      attrs[:shell] = argv.first
      argv.drop(1).each_with_index { |word, i| attrs[:"param#{i + 1}"] = word }
    end
    attrs
  end

  # Mixed into a plugin's main class.
  module Commands
    private

    def plugin_name
      MenuKit.plugin_name
    end

    def printer
      @printer ||= Printer.new
    end

    # Runs a program and returns its output. Raises CommandFailed when it exits
    # with an error.
    def cmd(*argv, dir: nil)
      options = dir ? { chdir: File.expand_path(dir) } : {}
      out, err, status = Open3.capture3(*argv, options)
      return out if status.success?

      detail = err.to_s.strip
      raise CommandFailed, "#{argv.join(' ')} exited #{status.exitstatus}#{detail.empty? ? '' : ": #{detail}"}"
    end
  end

  class Printer
    def initialize(depth = 0)
      @depth = depth
    end

    # One menu line. A block gets a Printer for the submenu below it. `alt:` is
    # the text shown instead while Option is held; it gets the submenu too.
    def item(label = nil, alt: nil, **attrs)
      return if label.to_s.empty?

      attrs = MenuKit.attributes(attrs)
      write(label, attrs)
      yield Printer.new(@depth + 1) if block_given?
      return if alt.to_s.strip.empty?

      write(alt, attrs.merge(alternate: true))
      yield Printer.new(@depth + 1) if block_given?
    end

    def sep
      write('---', {})
    end
    alias separator sep

    private

    def write(text, attrs)
      line = "#{'--' * @depth}#{text}"
      line += " | #{attrs.map { |key, value| %(#{key}="#{value}") }.join(' ')}" unless attrs.empty?
      $stdout.puts(line)
    end
  end

  def dispatch(plugin, argv = ARGV)
    return plugin.run if argv.empty?

    name, *args = argv
    raise UnknownCall, "#{File.basename($PROGRAM_NAME)} has no action #{name}" unless plugin.respond_to?(name)

    plugin.public_send(name, *args)
  end

  # A crashed plugin prints a ":warning:" title, which quietbar turns into an
  # error row holding the message and backtrace.
  def crash(error)
    lines = error.message.to_s.lines.map(&:chomp).reject(&:empty?)
    lines += (error.backtrace || []).map { |line| "--#{line}" }
    puts ":warning: #{File.basename($PROGRAM_NAME)}", '---', *lines
    exit 0
  end
end
