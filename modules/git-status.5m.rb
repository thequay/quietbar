#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>Git Status</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.desc>Dirty, unpushed, stashed and mid-operation repos under your projects folder (~/git)</xbar.desc>
# <xbar.dependencies>ruby,git</xbar.dependencies>
#
# Read-only and offline: git runs with optional locks off (no index.lock, no
# index refresh), no fsmonitor and no prompts, and never fetches. Ahead and
# behind come from the upstream refs as of the last fetch.

require 'open3'

require_relative '../lib/menu_kit'

module Git
  # One repo's state. Either parsed from git, or timed_out / error is set.
  Repo = Struct.new(:path, :rel, :branch, :upstream, :ahead, :behind, :stash,
                    :staged, :modified, :untracked, :conflicts, :files,
                    :operations, :worktree, :commits, :subject, :age,
                    :timed_out, :error, keyword_init: true) do
    def changed
      files.size
    end

    def detached?
      branch == '(detached)'
    end

    def no_upstream?
      commits && upstream.nil? && !detached?
    end

    def upstream_gone?
      !upstream.nil? && ahead.nil?
    end

    def attention?
      timed_out || changed.positive? || ahead.to_i.positive? || no_upstream? ||
        upstream_gone? || stash.positive? || !operations.empty? || detached?
    end

    # Lower sorts first.
    def severity
      return 0 if !operations.empty? || conflicts.positive?
      return 1 if timed_out
      return 2 if changed.positive?
      return 3 if ahead.to_i.positive?

      4
    end
  end

  class Status

    PREFIX = 'arrow.triangle.branch'
    ROOT = File.expand_path(ENV['QUIETBAR_PROJECTS_DIR'] || '~/git')
    MAX_DEPTH = 5
    SKIP_DIRS = %w[node_modules vendor build dist target Pods venv
                   __pycache__].freeze

    THREADS = 8
    TOTAL_BUDGET = 20 # seconds for the whole scan
    REPO_BUDGET = 15  # seconds for one repo
    LISTED_FILES = 10

    GIT_ENV = {
      'GIT_OPTIONAL_LOCKS' => '0', 'GIT_TERMINAL_PROMPT' => '0',
      'LC_ALL' => 'C'
    }.freeze
    GIT_FLAGS = ['--no-optional-locks', '-c', 'core.fsmonitor=false',
                 '-c', 'core.quotePath=false'].freeze

    OPERATIONS = {
      'rebase-merge' => 'rebase in progress',
      'rebase-apply' => 'rebase or am in progress',
      'MERGE_HEAD' => 'merge in progress',
      'CHERRY_PICK_HEAD' => 'cherry-pick in progress',
      'REVERT_HEAD' => 'revert in progress',
      'BISECT_LOG' => 'bisect in progress'
    }.freeze

    def run
      started = Time.now
      repos = scan(discover(ROOT), started + TOTAL_BUDGET)
      elapsed = Time.now - started

      good = repos.reject(&:error)
      skipped = repos.select(&:error)
      attention = good.select(&:attention?)
                      .sort_by { |r| [r.severity, r.rel] }
      clean = good.reject(&:attention?).sort_by(&:rel)

      print_title(attention)
      printer.sep
      printer.item('⏳ Refresh', alt: '⏳ Refresh (⌘R)', refresh: true)

      printer.sep
      if attention.empty?
        printer.item('All repos clean')
      else
        printer.item("Needs attention (#{attention.size}):")
        attention.each { |repo| print_attention(printer, repo) }
      end

      unless clean.empty?
        printer.sep
        printer.item("Clean (#{clean.size})") do |sub|
          clean.each { |repo| print_clean(sub, repo) }
        end
      end

      unless skipped.empty?
        printer.sep
        printer.item("Unreadable (#{skipped.size})") do |sub|
          skipped.each { |repo| sub.item("#{repo.rel}: #{truncate(repo.error)}") }
        end
      end

      printer.sep
      printer.item(format('%d repos · scanned in %.1fs · ahead/behind as of last fetch',
                          good.size, elapsed))
    end

    # RPC method, called through the menu items.
    def copy(*args)
      IO.popen('pbcopy', 'w') { |io| io.print(args.join(' ')) }
    end

    private

    def printer
      @printer ||= MenuKit::Printer.new
    end

    def print_title(attention)
      if attention.empty?
        printer.item('0', sfimage: PREFIX, color: '#34C759', dropdown: false)
      else
        printer.item(attention.size.to_s, sfimage: PREFIX, dropdown: false)
      end
    end

    # --- discovery -----------------------------------------------------------

    # Directories holding a .git dir or file. A repo is never descended into,
    # so submodules and nested clones inside one are not listed on their own.
    def discover(dir, depth = 0, found = [])
      return found if depth > MAX_DEPTH

      Dir.children(dir).sort.each do |name|
        next if name.start_with?('.') || SKIP_DIRS.include?(name)

        path = File.join(dir, name)
        next unless File.lstat(path).directory? # symlinks could loop or double count

        if File.exist?(File.join(path, '.git'))
          found << path
        else
          discover(path, depth + 1, found)
        end
      rescue SystemCallError
        next
      end
      found
    rescue SystemCallError
      found
    end

    # --- scanning ------------------------------------------------------------

    def scan(paths, deadline)
      queue = Queue.new
      paths.each { |p| queue << p }
      results = Queue.new

      workers = Array.new([THREADS, paths.size].min) do
        Thread.new do
          loop do
            path = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            results << inspect_repo(path, deadline)
          end
        end
      end
      workers.each(&:join)

      Array.new(results.size) { results.pop }.compact
    end

    TimedOut = Class.new(StandardError)
    GitFailed = Class.new(StandardError)

    # Runs git in dir, killing it (and its children) at the deadline.
    def git(dir, *args, deadline)
      limit = [deadline - Time.now, 0].max
      out = err = nil
      status = nil
      Open3.popen3(GIT_ENV, 'git', *GIT_FLAGS, '-C', dir, *args,
                   pgroup: true) do |stdin, stdout, stderr, thread|
        stdin.close
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        unless thread.join(limit)
          begin
            Process.kill('KILL', -thread.pid)
          rescue SystemCallError
            nil
          end
          thread.join
          readers.each(&:join)
          raise TimedOut
        end
        out, err = readers.map(&:value)
        status = thread.value
      end
      raise GitFailed, err.to_s.lines.first.to_s.strip unless status.success?

      out
    end

    def inspect_repo(path, total_deadline)
      rel = path.sub("#{ROOT}/", '')
      repo = Repo.new(path: path, rel: rel, ahead: nil, behind: nil, stash: 0,
                      staged: 0, modified: 0, untracked: 0, conflicts: 0,
                      files: [], operations: [], commits: false)
      return mark_timed_out(repo) if Time.now >= total_deadline

      deadline = [total_deadline, Time.now + REPO_BUDGET].min
      gitdir = gitdir_of(path)
      repo.worktree = gitdir.include?('/worktrees/')
      repo.operations = OPERATIONS.select { |f, _| File.exist?(File.join(gitdir, f)) }.values

      parse_status(repo, git(path, 'status', '--porcelain=v2', '--branch',
                             *('--show-stash' unless repo.worktree), deadline))
      load_last_commit(repo, deadline) if repo.commits
      repo
    rescue TimedOut
      mark_timed_out(repo)
    rescue GitFailed, SystemCallError => e
      repo.error = e.message.empty? ? 'not a readable git repo' : e.message
      repo
    end

    def mark_timed_out(repo)
      repo.timed_out = true
      repo.branch ||= '?'
      repo
    end

    def gitdir_of(path)
      dot_git = File.join(path, '.git')
      return dot_git if File.directory?(dot_git)

      pointer = File.read(dot_git)[/\Agitdir:\s*(.+)$/, 1]
      raise GitFailed, 'broken .git file' unless pointer

      File.expand_path(pointer.strip, path)
    end

    def parse_status(repo, text)
      text.each_line do |line|
        line = line.chomp
        case line[0]
        when '#' then parse_header(repo, line)
        when '1' then add_file(repo, line.split(' ', 9), 8)
        when '2' then add_file(repo, line.split(' ', 10), 9)
        when 'u' then add_conflict(repo, line.split(' ', 11)[10])
        when '?' then add_untracked(repo, line[2..])
        end
      end
    end

    def parse_header(repo, line)
      case line
      when /\A# branch\.oid (\S+)/ then repo.commits = Regexp.last_match(1) != '(initial)'
      when /\A# branch\.head (.+)/ then repo.branch = Regexp.last_match(1)
      when /\A# branch\.upstream (.+)/ then repo.upstream = Regexp.last_match(1)
      when /\A# branch\.ab \+(\d+) -(\d+)/
        repo.ahead = Regexp.last_match(1).to_i
        repo.behind = Regexp.last_match(2).to_i
      when /\A# stash (\d+)/ then repo.stash = Regexp.last_match(1).to_i
      end
    end

    def add_file(repo, fields, path_index)
      x, y = fields[1].chars
      path = fields[path_index].to_s.split("\t").first
      repo.staged += 1 unless x == '.'
      repo.modified += 1 unless y == '.'
      repo.files << { x: x, y: y, path: path, kind: :tracked }
    end

    def add_conflict(repo, path)
      repo.conflicts += 1
      repo.files << { x: 'U', y: 'U', path: path, kind: :conflict }
    end

    def add_untracked(repo, path)
      repo.untracked += 1
      repo.files << { x: '?', y: '?', path: path, kind: :untracked }
    end

    def load_last_commit(repo, deadline)
      out = git(repo.path, 'log', '-1', '--format=%ct%x09%s', deadline)
      time, subject = out.chomp.split("\t", 2)
      repo.subject = subject
      repo.age = Time.now.to_i - time.to_i
    rescue GitFailed
      nil
    end

    # --- output --------------------------------------------------------------

    def summary(repo)
      parts = [repo.rel, repo.branch]
      return parts.push('⏱ timed out, not scanned').join(' · ') if repo.timed_out

      counts = []
      counts << "●#{repo.changed}" if repo.changed.positive?
      counts << "↑#{repo.ahead}" if repo.ahead.to_i.positive?
      counts << "↓#{repo.behind}" if repo.behind.to_i.positive?
      parts << counts.join(' ') unless counts.empty?
      parts << "#{repo.stash} stash" if repo.stash.positive?
      parts << 'no upstream' if repo.no_upstream?
      parts << 'upstream gone' if repo.upstream_gone?
      parts << 'worktree' if repo.worktree
      parts.concat(repo.operations.map { |op| "⚠ #{op}" })
      parts.join(' · ')
    end

    def print_attention(printer, repo)
      icon = case repo.severity
             when 0 then '🔴'
             when 1 then '⏱'
             else '🟡'
             end
      printer.item("#{icon} #{truncate(summary(repo))}") do |sub|
        print_actions(sub, repo)
        sub.sep
        print_details(sub, repo)
      end
    end

    def print_clean(printer, repo)
      line = [repo.rel, repo.branch]
      line << "↓#{repo.behind}" if repo.behind.to_i.positive?
      line << 'worktree' if repo.worktree
      printer.item(truncate(line.join(' · '))) do |sub|
        print_actions(sub, repo)
        sub.sep
        print_details(sub, repo)
      end
    end

    def print_actions(printer, repo)
      printer.item('Open folder in Finder', shell: ['/usr/bin/open', repo.path])
      printer.item('Open in Terminal',
                   shell: ['/usr/bin/open', '-a', 'Terminal', repo.path])
      printer.item('Copy path', rpc: ['copy', repo.path])
    end

    def print_details(printer, repo)
      printer.item("Path: #{repo.path}")
      return printer.item('⏱ Timed out: status did not finish in time') if repo.timed_out

      repo.operations.each { |op| printer.item("⚠ Mid-operation: #{op}") }
      printer.item('⚠ Detached HEAD') if repo.detached?
      printer.item('⚠ Linked worktree (stashes are shared and counted in the main repo)') if repo.worktree
      print_branch(printer, repo)
      print_changes(printer, repo)
      printer.item("Stashes: #{repo.stash}") if repo.stash.positive?
      print_last_commit(printer, repo)
    end

    def print_branch(printer, repo)
      line = if repo.upstream
               "Branch: #{repo.branch} → #{repo.upstream}"
             else
               "Branch: #{repo.branch} (no upstream)"
             end
      line += ' (upstream gone)' if repo.upstream_gone?
      printer.item(truncate(line))
    end

    def print_changes(printer, repo)
      return if repo.files.empty?

      parts = []
      parts << "#{repo.staged} staged" if repo.staged.positive?
      parts << "#{repo.modified} modified" if repo.modified.positive?
      parts << "#{repo.untracked} untracked" if repo.untracked.positive?
      parts << "#{repo.conflicts} conflicted" if repo.conflicts.positive?
      printer.sep
      printer.item("Changes: #{parts.join(' · ')}")
      repo.files.first(LISTED_FILES).each do |f|
        printer.item(truncate("#{f[:x]}#{f[:y]} #{f[:path]}", 100),
                     font: 'Menlo', size: 12)
      end
      rest = repo.files.size - LISTED_FILES
      printer.item("… and #{rest} more") if rest.positive?
      printer.sep
    end

    def print_last_commit(printer, repo)
      return printer.item('No commits yet') unless repo.commits
      return unless repo.subject

      printer.item(truncate("Last commit: #{repo.subject} (#{age(repo.age)} ago)"))
    end

    def truncate(text, max = 140)
      text = text.tr('|', '¦') # a pipe would start SwiftBar's parameters
      text.length > max ? "#{text[0, max - 1]}…" : text
    end

    def age(seconds)
      minutes = seconds / 60
      return 'under a minute' if minutes < 1
      return "#{minutes}m" if minutes < 60
      return "#{minutes / 60}h" if minutes < 60 * 24

      days = minutes / (60 * 24)
      return "#{days}d" if days < 14
      return "#{days / 7}w" if days < 60
      return "#{days / 30}mo" if days < 365

      "#{days / 365}y"
    end
  end
end

begin
  service = Git::Status.new
  MenuKit.dispatch(service, ARGV)
rescue StandardError => e
  MenuKit.crash(e)
end
