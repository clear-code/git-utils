#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
#
# Copyright (C) 2009  Ryo Onodera <onodera@clear-code.com>
# Copyright (C) 2012-2013  Kouhei Sutou <kou@clear-code.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# See also post-receive-email in git for git repository
# change detection:
#   http://git.kernel.org/?p=git/git.git;a=blob;f=contrib/hooks/post-receive-email

require 'English'
require "optparse"
require "ostruct"
require "time"
require "net/smtp"
require "socket"
require "nkf"
require "shellwords"
require "erb"
require "digest"

class SpentTime
  def initialize(label)
    @label = label
    @seconds = 0.0
  end

  def spend
    start_time = Time.now
    returned_object = yield
    @seconds += (Time.now - start_time)
    returned_object
  end

  def report
    puts "#{"%0.9s" % @seconds} seconds spent by #{@label}."
  end
end

class GitCommitMailer
  VERSION = "1.0.0"
  URL = "https://github.com/clear-code/git-utils"

  KILO_SIZE = 1000
  DEFAULT_MAX_SIZE = "100M"

  class << self
    def x_mailer
      "#{name} #{VERSION}; #{URL}"
    end

    def execute(command, working_directory=nil, &block)
      if ENV['DEBUG']
        suppress_stderr = ''
      else
        suppress_stderr = ' 2> /dev/null'
      end

      script = "#{command} #{suppress_stderr}"
      puts script if ENV['DEBUG']
      result = nil
      with_working_direcotry(working_directory) do
        if block_given?
          IO.popen(script, "w+", &block)
        else
          result = `#{script} 2>&1`
        end
      end
      raise "execute failed: #{command}\n#{result}" unless $?.exitstatus.zero?
      result.force_encoding("UTF-8") if result.respond_to?(:force_encoding)
      result
    end

    def with_working_direcotry(working_directory)
      if working_directory
        Dir.chdir(working_directory) do
          yield
        end
      else
        yield
      end
    end

    def shell_escape(string)
      # To suppress warnings from Shellwords::escape.
      if string.respond_to? :force_encoding
        bytes = string.dup.force_encoding("ascii-8bit")
      else
        bytes = string
      end

      Shellwords.escape(bytes)
    end

    def git(git_bin_path, repository, command, &block)
      $executing_git ||= SpentTime.new("executing git commands")
      $executing_git.spend do
        execute("#{git_bin_path} --git-dir=#{shell_escape(repository)} #{command}", &block)
      end
    end

    def short_revision(revision)
      revision[0, 7]
    end

    def extract_email_address(address)
      if /<(.+?)>/ =~ address
        $1
      else
        address
      end
    end

    def extract_email_address_from_mail(mail)
      begin
        from_header = mail.lines.grep(/\AFrom: .*\Z/)[0]
        extract_email_address(from_header.rstrip.sub(/From: /, ""))
      rescue
        raise '"From:" header is not found in mail.'
      end
    end

    def extract_to_addresses(mail)
      to_value = nil
      if /^To:(.*\r?\n(?:^\s+.*)*)/n =~ mail
        to_value = $1
      else
        raise "'To:' header is not found in mail:\n#{mail}"
      end
      to_value_without_comment = to_value.gsub(/".*?"/n, "")
      to_value_without_comment.split(/\s*,\s*/n).collect do |address|
        extract_email_address(address.strip)
      end
    end

    def send_mail(server, port, from, to, mail)
      $sending_mail ||= SpentTime.new("sending mails")
      $sending_mail.spend do
        Net::SMTP.start(server, port) do |smtp|
          smtp.open_message_stream(from, to) do |f|
            f.print(mail)
          end
        end
      end
    end

    def parse_options_and_create(argv=nil)
      argv ||= ARGV
      to, options = parse(argv)
      to += options.to
      mailer = new(to.compact)
      apply_options(mailer, options)
      mailer
    end

    def parse(argv)
      options = make_options

      parser = make_parser(options)
      argv = argv.dup
      parser.parse!(argv)
      to = argv

      [to, options]
    end

    def format_size(size)
      return "no limit" if size.nil?
      return "#{size}B" if size < KILO_SIZE
      size /= KILO_SIZE.to_f
      return "#{size}KB" if size < KILO_SIZE
      size /= KILO_SIZE.to_f
      return "#{size}MB" if size < KILO_SIZE
      size /= KILO_SIZE.to_f
      "#{size}GB"
    end

    private
    def apply_options(mailer, options)
      mailer.repository = options.repository
      #mailer.reference = options.reference
      mailer.repository_browser = options.repository_browser
      mailer.github_base_url = options.github_base_url
      mailer.github_user = options.github_user
      mailer.github_repository = options.github_repository
      mailer.send_per_to = options.send_per_to
      mailer.from = options.from
      mailer.from_domain = options.from_domain
      mailer.sender = options.sender
      mailer.add_diff = options.add_diff
      mailer.add_html = options.add_html
      mailer.max_size = options.max_size
      mailer.repository_uri = options.repository_uri
      mailer.rss_path = options.rss_path
      mailer.rss_uri = options.rss_uri
      mailer.show_path = options.show_path
      mailer.send_push_mail = options.send_push_mail
      mailer.name = options.name
      mailer.server = options.server
      mailer.port = options.port
      mailer.date = options.date
      mailer.git_bin_path = options.git_bin_path
      mailer.track_remote = options.track_remote
      mailer.verbose = options.verbose
    end

    def parse_size(size)
      case size
      when /\A(.+?)GB?\z/i
        Float($1) * KILO_SIZE ** 3
      when /\A(.+?)MB?\z/i
        Float($1) * KILO_SIZE ** 2
      when /\A(.+?)KB?\z/i
        Float($1) * KILO_SIZE
      when /\A(.+?)B?\z/i
        Float($1)
      else
        raise ArgumentError, "invalid size: #{size.inspect}"
      end
    end

    def make_options
      options = OpenStruct.new
      options.repository = ".git"
      #options.reference = "refs/heads/master"
      options.repository_browser = nil
      options.github_base_url = "https://github.com"
      options.github_user = nil
      options.github_repository = nil
      options.to = []
      options.send_per_to = false
      options.error_to = []
      options.from = nil
      options.from_domain = nil
      options.sender = nil
      options.add_diff = true
      options.add_html = false
      options.max_size = parse_size(DEFAULT_MAX_SIZE)
      options.repository_uri = nil
      options.rss_path = nil
      options.rss_uri = nil
      options.show_path = false
      options.send_push_mail = false
      options.name = nil
      options.server = "localhost"
      options.port = Net::SMTP.default_port
      options.date = nil
      options.git_bin_path = "git"
      options.track_remote = false
      options.verbose = false
      options
    end

    def make_parser(options)
      OptionParser.new do |parser|
        parser.banner += "TO"

        add_repository_options(parser, options)
        add_email_options(parser, options)
        add_output_options(parser, options)
        add_rss_options(parser, options)
        add_other_options(parser, options)

        parser.on_tail("--help", "Show this message") do
          puts parser
          exit!
        end
      end
    end

    def add_repository_options(parser, options)
      parser.separator ""
      parser.separator "Repository related options:"

      parser.on("--repository=PATH",
                "Use PATH as the target git repository",
                "(#{options.repository})") do |path|
        options.repository = path
      end

      parser.on("--reference=REFERENCE",
                "Use REFERENCE as the target reference",
                "(#{options.reference})") do |reference|
        options.reference = reference
      end

      available_softwares = [:github]
      parser.on("--repository-browser=SOFTWARE",
                available_softwares,
                "Use SOFTWARE as the repository browser",
                "(available repository browsers: " +
                  available_softwares.join(", ")) do |software|
        options.repository_browser = software
      end

      add_github_options(parser, options)
    end

    def add_github_options(parser, options)
      parser.separator ""
      parser.separator "GitHub related options:"

      parser.on("--github-base-url=URL",
                "Use URL as base URL of GitHub",
                "(#{options.github_base_url})") do |url|
        options.github_base_url = url
      end

      parser.on("--github-user=USER",
                "Use USER as the GitHub user") do |user|
        options.github_user = user
      end

      parser.on("--github-repository=REPOSITORY",
                "Use REPOSITORY as the GitHub repository") do |repository|
        options.github_repository = repository
      end
    end

    def add_email_options(parser, options)
      parser.separator ""
      parser.separator "E-mail related options:"

      parser.on("-sSERVER", "--server=SERVER",
                "Use SERVER as SMTP server (#{options.server})") do |server|
        options.server = server
      end

      parser.on("-pPORT", "--port=PORT", Integer,
                "Use PORT as SMTP port (#{options.port})") do |port|
        options.port = port
      end

      parser.on("-tTO", "--to=TO", "Add TO to To: address") do |to|
        options.to << to unless to.nil?
      end

      parser.on("--[no-]send-per-to",
                "Send a mail for each To: address",
                "instead of sending a mail for all To: addresses",
                "(#{options.send_per_to})") do |boolean|
        options.send_per_to = boolean
      end

      parser.on("-eTO", "--error-to=TO",
                "Add TO to To: address when an error occurs") do |to|
        options.error_to << to unless to.nil?
      end

      parser.on("-fFROM", "--from=FROM", "Use FROM as from address") do |from|
        if options.from_domain
          raise OptionParser::CannotCoexistOption,
                  "cannot coexist with --from-domain"
        end
        options.from = from
      end

      parser.on("--from-domain=DOMAIN",
                "Use author@DOMAIN as from address") do |domain|
        if options.from
          raise OptionParser::CannotCoexistOption,
                  "cannot coexist with --from"
        end
        options.from_domain = domain
      end

      parser.on("--sender=SENDER",
                "Use SENDER as a sender address") do |sender|
        options.sender = sender
      end
    end

    def add_output_options(parser, options)
      parser.separator ""
      parser.separator "Output related options:"

      parser.on("--name=NAME", "Use NAME as repository name") do |name|
        options.name = name
      end

      parser.on("--[no-]show-path",
                "Show commit target path") do |bool|
        options.show_path = bool
      end

      parser.on("--[no-]send-push-mail",
                "Send push mail") do |bool|
        options.send_push_mail = bool
      end

      parser.on("--repository-uri=URI",
                "Use URI as URI of repository") do |uri|
        options.repository_uri = uri
      end

      parser.on("-n", "--no-diff", "Don't add diffs") do |diff|
        options.add_diff = false
      end

      parser.on("--[no-]add-html",
                "Add HTML as alternative content") do |add_html|
        options.add_html = add_html
      end

      parser.on("--max-size=SIZE",
                "Limit mail body size to SIZE",
                "G/GB/M/MB/K/KB/B units are available",
                "(#{format_size(options.max_size)})") do |max_size|
        begin
          options.max_size = parse_size(max_size)
        rescue ArgumentError
          raise OptionParser::InvalidArgument, max_size
        end
      end

      parser.on("--no-limit-size",
                "Don't limit mail body size",
                "(#{options.max_size.nil?})") do |not_limit_size|
        options.max_size = nil
      end

      parser.on("--date=DATE",
                "Use DATE as date of push mails (Time.parse is used)") do |date|
        options.date = Time.parse(date)
      end

      parser.on("--git-bin-path=GIT_BIN_PATH",
                "Use GIT_BIN_PATH command instead of default \"git\"") do |git_bin_path|
        options.git_bin_path = git_bin_path
      end

      parser.on("--track-remote",
                "Fetch new commits from repository's origin and send mails") do
        options.track_remote = true
      end
    end

    def add_rss_options(parser, options)
      parser.separator ""
      parser.separator "RSS related options:"

      parser.on("--rss-path=PATH", "Use PATH as output RSS path") do |path|
        options.rss_path = path
      end

      parser.on("--rss-uri=URI", "Use URI as output RSS URI") do |uri|
        options.rss_uri = uri
      end
    end

    def add_other_options(parser, options)
      parser.separator ""
      parser.separator "Other options:"

      #parser.on("-IPATH", "--include=PATH", "Add PATH to load path") do |path|
      #  $LOAD_PATH.unshift(path)
      #end
      parser.on("--[no-]verbose",
                "Be verbose.",
                "(#{options.verbose})") do |verbose|
        options.verbose = verbose
      end
    end
  end

  attr_reader :reference, :old_revision, :new_revision, :to
  attr_writer :send_per_to
  attr_writer :from, :add_diff, :add_html, :show_path, :send_push_mail
  attr_writer :repository, :date, :git_bin_path, :track_remote
  attr_accessor :from_domain, :sender, :max_size, :repository_uri
  attr_accessor :rss_path, :rss_uri, :server, :port
  attr_accessor :repository_browser
  attr_accessor :github_base_url, :github_user, :github_repository
  attr_writer :name, :verbose

  def initialize(to)
    @to = to
  end

  def create_push_info(*args)
    PushInfo.new(self, *args)
  end

  def create_commit_info(*args)
    CommitInfo.new(self, *args)
  end

  def git(command, &block)
    GitCommitMailer.git(git_bin_path, @repository, command, &block)
  end

  def get_record(revision, record)
    get_records(revision, [record]).first
  end

  def get_records(revision, records)
    GitCommitMailer.git(git_bin_path, @repository,
                        "log -n 1 --pretty=format:'#{records.join('%n')}%n' " +
                        "#{revision}").lines.collect do |line|
      line.strip
    end
  end

  def send_per_to?
    @send_per_to
  end

  def from(info)
    if @from
      if /\A[^\s<]+@[^\s>]\z/ =~ @from
        @from
      else
        "#{info.author_name} <#{@from}>"
      end
    else
      # return "#{info.author_name}@#{@from_domain}".sub(/@\z/, '') if @from_domain
      "#{info.author_name} <#{info.author_email}>"
    end
  end

  def repository
    @repository || Dir.pwd
  end

  def date
    @date || Time.now
  end

  def git_bin_path
    ENV['GIT_BIN_PATH'] || @git_bin_path
  end

  def track_remote?
    @track_remote
  end

  def verbose?
    @verbose
  end

  def short_new_revision
    GitCommitMailer.short_revision(@new_revision)
  end

  def short_old_revision
    GitCommitMailer.short_revision(@old_revision)
  end

  def origin_references
    references = Hash.new("0" * 40)
    git("rev-parse --symbolic-full-name --tags --remotes").lines.each do |reference|
      reference.rstrip!
      next if reference =~ %r!\Arefs/remotes! and reference !~ %r!\Arefs/remotes/origin!
      references[reference] = git("rev-parse %s" % GitCommitMailer.shell_escape(reference)).rstrip
    end
    references
  end

  def delete_tags
    git("rev-parse --symbolic --tags").lines.each do |reference|
      reference.rstrip!
      git("tag -d %s" % GitCommitMailer.shell_escape(reference))
    end
  end

  def fetch
    updated_references = []
    old_references = origin_references
    delete_tags
    git("fetch --force --tags")
    git("fetch --force")
    new_references = origin_references

    old_references.each do |reference, revision|
      if revision != new_references[reference]
        updated_references << [revision, new_references[reference], reference]
      end
    end
    new_references.each do |reference, revision|
      if revision != old_references[reference]#.sub(/remotes\/origin/, 'heads')
        updated_references << [old_references[reference], revision, reference]
      end
    end
    updated_references.sort do |reference_change1, reference_change2|
      reference_change1.last <=> reference_change2.last
    end.uniq
  end

  def detect_change_type
    if old_revision =~ /0{40}/ and new_revision =~ /0{40}/
      raise "Invalid revision hash"
    elsif old_revision !~ /0{40}/ and new_revision !~ /0{40}/
      :update
    elsif old_revision =~ /0{40}/
      :create
    elsif new_revision =~ /0{40}/
      :delete
    else
      raise "Invalid revision hash"
    end
  end

  def detect_object_type(object_name)
    git("cat-file -t #{object_name}").strip
  end

  def detect_revision_type(change_type)
    case change_type
    when :create, :update
      detect_object_type(new_revision)
    when :delete
      detect_object_type(old_revision)
    end
  end

  def detect_reference_type(revision_type)
    if reference =~ /refs\/tags\/.*/ and revision_type == "commit"
      :unannotated_tag
    elsif reference =~ /refs\/tags\/.*/ and revision_type == "tag"
      # change recipients
      #if [ -n "$announcerecipients" ]; then
      #  recipients="$announcerecipients"
      #fi
      :annotated_tag
    elsif reference =~ /refs\/(heads|remotes\/origin)\/.*/ and revision_type == "commit"
      :branch
    elsif reference =~ /refs\/remotes\/.*/ and revision_type == "commit"
      # tracking branch
      # Push-update of tracking branch.
      # no email generated.
      throw :no_email
    else
      # Anything else (is there anything else?)
      raise "Unknown type of update to #@reference (#{revision_type})"
    end
  end

  def make_push_message(reference_type, change_type)
    unless [:update, :create, :delete].include?(change_type)
      raise "unexpected change_type"
    end

    if reference_type == :branch
      if change_type == :update
        process_update_branch
      elsif change_type == :create
        process_create_branch
      elsif change_type == :delete
        process_delete_branch
      end
    elsif reference_type == :annotated_tag
      if change_type == :update
        process_update_annotated_tag
      elsif change_type == :create
        process_create_annotated_tag
      elsif change_type == :delete
        process_delete_annotated_tag
      end
    elsif reference_type == :unannotated_tag
      if change_type == :update
        process_update_unannotated_tag
      elsif change_type == :create
        process_create_unannotated_tag
      elsif change_type == :delete
        process_delete_unannotated_tag
      end
    else
      raise "unexpected reference_type"
    end
  end

  def collect_push_information
    change_type = detect_change_type
    revision_type = detect_revision_type(change_type)
    reference_type = detect_reference_type(revision_type)
    messsage, commits = make_push_message(reference_type, change_type)

    [reference_type, change_type, messsage, commits]
  end

  def excluded_revisions
     # refer to the long comment located at the top of this file for the
     # explanation of this command.
     current_reference_revision = git("rev-parse #@reference").strip
     git("rev-parse --not --branches --remotes").lines.find_all do |line|
       line.strip!
       not line.index(current_reference_revision)
     end.collect do |line|
       GitCommitMailer.shell_escape(line)
     end.join(' ')
  end

  def process_create_branch
    message = "Branch (#{@reference}) is created.\n"
    commits = []

    commit_list = []
    git("rev-list #{@new_revision} #{excluded_revisions}").lines.
    reverse_each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)
      commits << revision
      subject = get_record(revision, '%s')
      commit_list << "     via  #{short_revision} #{subject}\n"
    end
    if commit_list.length > 0
      commit_list[-1].sub!(/\A     via  /, '     at   ')
      message << commit_list.join
    end

    [message, commits]
  end

  def explain_rewind
<<EOF
This update discarded existing revisions and left the branch pointing at
a previous point in the repository history.

 * -- * -- N (#{short_new_revision})
            \\
             O <- O <- O (#{short_old_revision})

The removed revisions are not necessarilly gone - if another reference
still refers to them they will stay in the repository.
EOF
  end

  def explain_rewind_and_new_commits
<<EOF
This update added new revisions after undoing existing revisions.  That is
to say, the old revision is not a strict subset of the new revision.  This
situation occurs when you --force push a change and generate a repository
containing something like this:

 * -- * -- B <- O <- O <- O (#{short_old_revision})
            \\
             N -> N -> N (#{short_new_revision})

When this happens we assume that you've already had alert emails for all
of the O revisions, and so we here report only the revisions in the N
branch from the common base, B.
EOF
  end

  def process_backward_update
    # List all of the revisions that were removed by this update, in a
    # fast forward update, this list will be empty, because rev-list O
    # ^N is empty.  For a non fast forward, O ^N is the list of removed
    # revisions
    fast_forward = false
    revision_found = false
    commits_summary = []
    git("rev-list #{@new_revision}..#{@old_revision}").lines.each do |revision|
      revision_found ||= true
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)
      subject = get_record(revision, '%s')
      commits_summary << "discards  #{short_revision} #{subject}\n"
    end
    unless revision_found
      fast_forward = true
      subject = get_record(old_revision, '%s')
      commits_summary << "    from  #{short_old_revision} #{subject}\n"
    end
    [fast_forward, commits_summary]
  end

  def process_forward_update
    # List all the revisions from baserev to new_revision in a kind of
    # "table-of-contents"; note this list can include revisions that
    # have already had notification emails and is present to show the
    # full detail of the change from rolling back the old revision to
    # the base revision and then forward to the new revision
    commits_summary = []
    git("rev-list #{@old_revision}..#{@new_revision}").lines.each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)

      subject = get_record(revision, '%s')
      commits_summary << "     via  #{short_revision} #{subject}\n"
    end
    commits_summary
  end

  def explain_special_case
    #  1. Existing revisions were removed.  In this case new_revision
    #     is a subset of old_revision - this is the reverse of a
    #     fast-forward, a rewind
    #  2. New revisions were added on top of an old revision,
    #     this is a rewind and addition.

    # (1) certainly happened, (2) possibly.  When (2) hasn't
    # happened, we set a flag to indicate that no log printout
    # is required.

    # Find the common ancestor of the old and new revisions and
    # compare it with new_revision
    baserev = git("merge-base #{@old_revision} #{@new_revision}").strip
    rewind_only = false
    if baserev == new_revision
      explanation = explain_rewind
      rewind_only = true
    else
      explanation = explain_rewind_and_new_commits
    end
    [rewind_only, explanation]
  end

  def collect_new_commits
    commits = []
    git("rev-list #{@old_revision}..#{@new_revision} #{excluded_revisions}").lines.
    reverse_each do |revision|
      commits << revision.strip
    end
    commits
  end

  def process_update_branch
    message = "Branch (#{@reference}) is updated.\n"

    fast_forward, backward_commits_summary = process_backward_update
    forward_commits_summary = process_forward_update

    commits_summary = backward_commits_summary + forward_commits_summary.reverse

    unless fast_forward
      rewind_only, explanation = explain_special_case
      message << explanation
    end

    message << "\n"
    message << commits_summary.join

    unless rewind_only
      new_commits = collect_new_commits
    end
    if rewind_only or new_commits.empty?
      message << "\n"
      message << "No new revisions were added by this update.\n"
    end

    [message, new_commits]
  end

  def process_delete_branch
    "Branch (#{@reference}) is deleted.\n" +
    "       was  #{@old_revision}\n\n" +
    git("show -s --pretty=oneline #{@old_revision}")
  end

  def process_create_annotated_tag
    "Annotated tag (#{@reference}) is created.\n" +
    "        at  #{@new_revision} (tag)\n" +
    process_annotated_tag
  end

  def process_update_annotated_tag
    "Annotated tag (#{@reference}) is updated.\n" +
    "        to  #{@new_revision} (tag)\n" +
    "      from  #{@old_revision} (which is now obsolete)\n" +
    process_annotated_tag
  end

  def process_delete_annotated_tag
    "Annotated tag (#{@reference}) is deleted.\n" +
    "       was  #{@old_revision}\n\n" +
    git("show -s --pretty=oneline #{@old_revision}").sub(/^Tagger.*$/, '').
                                                     sub(/^Date.*$/, '').
                                                     sub(/\n{2,}/, "\n\n")
  end

  def short_log(revision_specifier)
    log = git("rev-list --pretty=short #{GitCommitMailer.shell_escape(revision_specifier)}")
    git("shortlog") do |git|
      git.write(log)
      git.close_write
      return git.read
    end
  end

  def short_log_from_previous_tag(previous_tag)
    if previous_tag
      # Show changes since the previous release
      short_log("#{previous_tag}..#{@new_revision}")
    else
      # No previous tag, show all the changes since time began
      short_log(@new_revision)
    end
  end

  class NoParentCommit < Exception
  end

  def parent_commit(revision)
    begin
      git("rev-parse #{revision}^").strip
    rescue
      raise NoParentCommit
    end
  end

  def previous_tag_by_revision(revision)
    # If the tagged object is a commit, then we assume this is a
    # release, and so we calculate which tag this tag is
    # replacing
    begin
      git("describe --abbrev=0 #{parent_commit(revision)}").strip
    rescue NoParentCommit
    end
  end

  def annotated_tag_content
    message = ''
    tagger = git("for-each-ref --format='%(taggername)' #{@reference}").strip
    tagged = git("for-each-ref --format='%(taggerdate:rfc2822)' #{@reference}").strip
    message << " tagged by  #{tagger}\n"
    message << "        on  #{format_time(Time.rfc2822(tagged))}\n\n"

    # Show the content of the tag message; this might contain a change
    # log or release notes so is worth displaying.
    tag_content = git("cat-file tag #{@new_revision}").split("\n")
    #skips header section
    tag_content.shift while not tag_content.first.empty?
    #skips the empty line indicating the end of header section
    tag_content.shift

    message << tag_content.join("\n") + "\n"
    message
  end

  def process_annotated_tag
    message = ''
    # Use git for-each-ref to pull out the individual fields from the tag
    tag_object = git("for-each-ref --format='%(*objectname)' #{@reference}").strip
    tag_type = git("for-each-ref --format='%(*objecttype)' #{@reference}").strip

    case tag_type
    when "commit"
      message << "   tagging  #{tag_object} (#{tag_type})\n"
      previous_tag = previous_tag_by_revision(@new_revision)
      message << "  replaces  #{previous_tag}\n" if previous_tag
      message << annotated_tag_content
      message << short_log_from_previous_tag(previous_tag)
    else
      message << "   tagging  #{tag_object} (#{tag_type})\n"
      message << "    length  #{git("cat-file -s #{tag_object}").strip} bytes\n"
      message << annotated_tag_content
    end

    message
  end

  def process_create_unannotated_tag
    raise "unexpected" unless detect_object_type(@new_revision) == "commit"

    "Unannotated tag (#{@reference}) is created.\n" +
    "        at  #{@new_revision} (commit)\n\n" +
    process_unannotated_tag(@new_revision)
  end

  def process_update_unannotated_tag
    raise "unexpected" unless detect_object_type(@new_revision) == "commit"
    raise "unexpected" unless detect_object_type(@old_revision) == "commit"

    "Unannotated tag (#{@reference}) is updated.\n" +
    "        to  #{@new_revision} (commit)\n" +
    "      from  #{@old_revision} (commit)\n\n" +
    process_unannotated_tag(@new_revision)
  end

  def process_delete_unannotated_tag
    raise "unexpected" unless detect_object_type(@old_revision) == "commit"

    "Unannotated tag (#{@reference}) is deleted.\n" +
    "       was  #{@old_revision} (commit)\n\n" +
    process_unannotated_tag(@old_revision)
  end

  def process_unannotated_tag(revision)
    git("show --no-color --root -s --pretty=short #{revision}")
  end

  def find_branch_name_from_its_descendant_revision(revision)
    until name.sub(/([~^][0-9]+)*\z/, '') == name
      name = git("name-rev --name-only --refs refs/heads/* #{revision}").strip
      revision = parent_commit(revision)
    end
    name
  end

  def traverse_merge_commit(merge_commit)
    first_grand_parent = parent_commit(merge_commit.first_parent)

    [merge_commit.first_parent, *merge_commit.other_parents].each do |revision|
      is_traversing_first_parent = (revision == merge_commit.first_parent)
      base_revision = git("merge-base #{first_grand_parent} #{revision}").strip
      base_revisions = [@old_revision, base_revision]
      #branch_name = find_branch_name_from_its_descendant_revision(revision)
      descendant_revision = merge_commit.revision

      until base_revisions.index(revision)
        commit_info = @commit_info_map[revision]
        if commit_info
          commit_info.reference = @reference
        else
          commit_info = create_commit_info(@reference, revision)
          index = @commit_infos.index(@commit_info_map[descendant_revision])
          @commit_infos.insert(index, commit_info)
          @commit_info_map[revision] = commit_info
        end

        merge_message = "Merged #{merge_commit.short_revision}: #{merge_commit.subject}"
        if not is_traversing_first_parent and not commit_info.merge_status.index(merge_message)
          commit_info.merge_status << merge_message
        end

        if commit_info.merge?
          traverse_merge_commit(commit_info)
          base_revision = git("merge-base #{first_grand_parent} #{commit_info.first_parent}").strip
          base_revisions << base_revision unless base_revisions.index(base_revision)
        end
        descendant_revision, revision = revision, commit_info.first_parent
      end
    end
  end

  def post_process_infos
    # @push_info.author_name = determine_prominent_author
    commit_infos = @commit_infos.dup
    # @commit_infos may be altered and I don't know any sensible behavior of ruby
    # in such cases. Take the safety measure at the moment...
    commit_infos.reverse_each do |commit_info|
      traverse_merge_commit(commit_info) if commit_info.merge?
    end
  end

  def determine_prominent_author
    #if @commit_infos.length > 0
    #
    #else
    #   @push_info
  end

  def reset(old_revision, new_revision, reference)
    @old_revision = old_revision
    @new_revision = new_revision
    @reference = reference

    @push_info = nil
    @commit_infos = []
    @commit_info_map = {}
  end

  def make_infos
    catch(:no_email) do
      @push_info = create_push_info(old_revision, new_revision, reference,
                                    *collect_push_information)
      if @push_info.branch_changed?
        @push_info.commits.each do |revision|
          commit_info = create_commit_info(reference, revision)
          @commit_infos << commit_info
          @commit_info_map[revision] = commit_info
        end
      end
    end

    post_process_infos
  end

  def make_mails
    if send_per_to?
      @push_mails = @to.collect do |to|
        make_mail(@push_info, [to])
      end
    else
      @push_mails = [make_mail(@push_info, @to)]
    end

    @commit_mails = []
    @commit_infos.each do |info|
      if send_per_to?
        @to.each do |to|
          @commit_mails << make_mail(info, [to])
        end
      else
        @commit_mails << make_mail(info, @to)
      end
    end
  end

  def process_reference_change(old_revision, new_revision, reference)
    reset(old_revision, new_revision, reference)

    make_infos
    make_mails
    if rss_output_available?
      output_rss
    end

    [@push_mails, @commit_mails]
  end

  def send_all_mails
    if send_push_mail?
      @push_mails.each do |mail|
        send_mail(mail)
      end
    end

    @commit_mails.each do |mail|
      send_mail(mail)
    end
  end

  def add_diff?
    @add_diff
  end

  def add_html?
    @add_html
  end

  def show_path?
    @show_path
  end

  def send_push_mail?
    @send_push_mail
  end

  def format_time(time)
    time.strftime('%Y-%m-%d %X %z (%a, %d %b %Y)')
  end

  private
  def send_mail(mail)
    server = @server || "localhost"
    port = @port
    from = sender || GitCommitMailer.extract_email_address_from_mail(mail)
    to = GitCommitMailer.extract_to_addresses(mail)
    GitCommitMailer.send_mail(server, port, from, to, mail)
  end

  def output_rss
    prev_rss = nil
    begin
      if File.exist?(@rss_path)
        File.open(@rss_path) do |f|
          prev_rss = RSS::Parser.parse(f)
        end
      end
    rescue RSS::Error
    end

    rss = make_rss(prev_rss).to_s
    File.open(@rss_path, "w") do |f|
      f.print(rss)
    end
  end

  def rss_output_available?
    if @repository_uri and @rss_path and @rss_uri
      begin
        require 'rss'
        true
      rescue LoadError
        false
      end
    else
      false
    end
  end

  def make_mail(info, to)
    @boundary = generate_boundary

    encoding = "utf-8"
    bit = "8bit"

    multipart_body_p = false
    body_text = info.format_mail_body_text
    body_html = nil
    if add_html?
      body_html = info.format_mail_body_html
      multipart_body_p = (body_text.size + body_html.size) < @max_size
    end

    if multipart_body_p
      body = <<-EOB
--#{@boundary}
Content-Type: text/plain; charset=#{encoding}
Content-Transfer-Encoding: #{bit}

#{body_text}
--#{@boundary}
Content-Type: text/html; charset=#{encoding}
Content-Transfer-Encoding: #{bit}

#{body_html}
--#{@boundary}--
EOB
    else
      body = truncate_body(body_text, @max_size)
    end

    header = make_header(encoding, bit, to, info, multipart_body_p)
    if header.respond_to?(:force_encoding)
      header.force_encoding("BINARY")
      body.force_encoding("BINARY")
    end
    header + "\n" + body
  end

  def name
    if @name
      @name
    else
      repository = File.expand_path(@repository)
      loop do
        basename = File.basename(repository, ".git")
        if basename != ".git"
          return basename
        else
          repository = File.dirname(repository)
        end
      end
    end
  end

  def make_header(body_encoding, body_encoding_bit, to, info, multipart_body_p)
    subject = "#{(name + ' ') if name}" +
              mime_encoded_word("#{info.format_mail_subject}")
    headers = []
    headers += info.headers
    headers << "X-Mailer: #{self.class.x_mailer}"
    headers << "MIME-Version: 1.0"
    if multipart_body_p
      headers << "Content-Type: multipart/alternative;"
      headers << " boundary=#{@boundary}"
    else
      headers << "Content-Type: text/plain; charset=#{body_encoding}"
      headers << "Content-Transfer-Encoding: #{body_encoding_bit}"
    end
    headers << "From: #{from(info)}"
    headers << "To: #{to.join(', ')}"
    headers << "Subject: #{subject}"
    headers << "Date: #{info.date.rfc2822}"
    headers << "Sender: #{sender}" if sender
    headers.find_all do |header|
      /\A\s*\z/ !~ header
    end.join("\n") + "\n"
  end

  def generate_boundary
    random_integer = Time.now.to_i * 1000 + rand(1000)
    Digest::SHA1.hexdigest(random_integer.to_s)
  end

  def detect_project
    project = File.open("#{repository}/description").gets.strip
    # Check if the description is unchanged from it's default, and shorten it to
    # a more manageable length if it is
    if project =~ /Unnamed repository.*$/
      project = nil
    end

    project
  end

  def mime_encoded_word(string)
    #XXX "-MWw" didn't work in some versions of Ruby 1.9.
    #    giving up to stick with UTF-8... ;)
    encoded_string = NKF.nkf("-MWj", string)

    #XXX The actual MIME encoded-word's string representaion is US-ASCII,
    #    which, in turn, can be UTF-8. In spite of this fact, in some versions
    #    of Ruby 1.9, encoded_string.encoding is incorrectly set as ISO-2022-JP.
    #    Fortunately, as we just said, we can just safely override them with
    #    "UTF-8" to work around this bug.
    if encoded_string.respond_to?(:force_encoding)
      encoded_string.force_encoding("UTF-8")
    end

    #XXX work around NKF's bug of gratuitously wrapping long ascii words with
    #    MIME encoded-word syntax's header and footer, while not actually
    #    encoding the payload as base64: just strip the header and footer out.
    encoded_string.gsub!(/\=\?EUC-JP\?B\?(.*)\?=\n /) {$1}
    encoded_string.gsub!(/(\n )*=\?US-ASCII\?Q\?(.*)\?=(\n )*/) {$2}

    encoded_string
  end

  def truncate_body(body, max_size)
    return body if max_size.nil?
    return body if body.size < max_size

    truncated_body = body[0, max_size]
    formatted_size = self.class.format_size(max_size)
    truncated_message = "... truncated to #{formatted_size}\n"
    truncated_message_size = truncated_message.size

    lf_index = truncated_body.rindex(/(?:\r|\r\n|\n)/)
    while lf_index
      if lf_index + truncated_message_size < max_size
        truncated_body[lf_index, max_size] = "\n#{truncated_message}"
        break
      else
        lf_index = truncated_body.rindex(/(?:\r|\r\n|\n)/, lf_index - 1)
      end
    end

    truncated_body
  end

  def make_rss(base_rss)
    RSS::Maker.make("1.0") do |maker|
      maker.encoding = "UTF-8"

      maker.channel.about = @rss_uri
      maker.channel.title = rss_title(name || @repository_uri)
      maker.channel.link = @repository_uri
      maker.channel.description = rss_title(@name || @repository_uri)
      maker.channel.dc_date = @push_info.date

      if base_rss
        base_rss.items.each do |item|
          item.setup_maker(maker)
        end
      end

      @commit_infos.each do |info|
        item = maker.items.new_item
        item.title = info.rss_title
        item.description = info.summary
        item.content_encoded = info.rss_content
        item.link = "#{@repository_uri}/commit/?id=#{info.revision}"
        item.dc_date = info.date
        item.dc_creator = info.author_name
      end

      maker.items.do_sort = true
      maker.items.max_size = 15
    end
  end

  def rss_title(name)
    "Repository of #{name}"
  end

  class Info
    class << self
      def host_name
        @@host_name ||= Socket.gethostbyname(Socket.gethostname).first
      end

      def host_name=(name)
        @@host_name = name
      end
    end

    def git(command, &block)
      @mailer.git(command, &block)
    end

    def get_record(record)
      @mailer.get_record(@revision, record)
    end

    def get_records(records)
      @mailer.get_records(@revision, records)
    end

    def short_reference
      @reference.sub(/\A.*\/.*\//, '')
    end
  end

  class PushInfo < Info
    attr_reader :old_revision, :new_revision, :reference, :reference_type, :log
    attr_reader :author_name, :author_email, :date, :subject, :change_type
    attr_reader :commits
    def initialize(mailer, old_revision, new_revision, reference,
                   reference_type, change_type, log, commits=[])
      @mailer = mailer
      @old_revision = old_revision
      @new_revision = new_revision
      if @new_revision != '0' * 40 #XXX well, i need to properly fix this bug later.
        @revision = @new_revision
      else
        @revision = @old_revision
      end
      @reference = reference
      @reference_type = reference_type
      @log = log
      author_name, author_email = get_records(["%an", "%ae"])
      @author_name = author_name
      @author_email = author_email
      @date = @mailer.date
      @change_type = change_type
      @commits = commits || []
    end

    def revision
      @new_revision
    end

    def message_id
      "<#{old_revision}.#{new_revision}@#{self.class.host_name}>"
    end

    def headers
      [
        "X-Git-OldRev: #{old_revision}",
        "X-Git-NewRev: #{new_revision}",
        "X-Git-Refname: #{reference}",
        "X-Git-Reftype: #{REFERENCE_TYPE[reference_type]}",
        "Message-ID: #{message_id}",
      ]
    end

    def branch_changed?
      !@commits.empty?
    end

    REFERENCE_TYPE = {
      :branch => "branch",
      :annotated_tag => "annotated tag",
      :unannotated_tag => "unannotated tag"
    }
    CHANGE_TYPE = {
      :create => "created",
      :update => "updated",
      :delete => "deleted",
    }

    def format_mail_subject
      "(push) #{PushInfo::REFERENCE_TYPE[reference_type]} " +
        "(#{short_reference}) is #{PushInfo::CHANGE_TYPE[change_type]}."
    end

    def format_mail_body_text
      body = ""
      body << "#{author_name}\t#{@mailer.format_time(date)}\n"
      body << "\n"
      body << "New Push:\n"
      body << "\n"
      body << "  Message:\n"
      log.rstrip.each_line do |line|
        body << "    #{line}"
      end
      body << "\n\n"
    end

    def format_mail_body_html
      "<pre>#{ERB::Util.h(format_mail_body_text)}</pre>"
    end
  end

  class CommitInfo < Info
    class << self
      def unescape_file_path(file_path)
        if file_path =~ /\A"(.*)"\z/
          escaped_file_path = $1
          if escaped_file_path.respond_to?(:encoding)
            encoding = escaped_file_path.encoding
          else
            encoding = nil
          end
          unescaped_file_path = escaped_file_path.gsub(/\\\\/, '\\').
                                                  gsub(/\\\"/, '"').
                                                  gsub(/\\([0-9]{1,3})/) do
            $1.to_i(8).chr
          end
          unescaped_file_path.force_encoding(encoding) if encoding
          unescaped_file_path
        else
          file_path
        end
      end
    end

    attr_reader :mailer, :revision, :reference
    attr_reader :added_files, :copied_files, :deleted_files, :updated_files
    attr_reader :renamed_files, :type_changed_files, :diffs
    attr_reader :subject, :author_name, :author_email, :date, :summary
    attr_accessor :merge_status
    attr_writer :reference
    def initialize(mailer, reference, revision)
      @mailer = mailer
      @reference = reference
      @revision = revision

      @files = []
      @added_files = []
      @copied_files = []
      @deleted_files = []
      @updated_files = []
      @renamed_files = []
      @type_changed_files = []

      set_records
      parse_file_status
      parse_diff

      @merge_status = []
    end

    def first_parent
      return nil if @parent_revisions.length.zero?

      @parent_revisions[0]
    end

    def other_parents
      return [] if @parent_revisions.length.zero?

      @parent_revisions[1..-1]
    end

    def merge?
      @parent_revisions.length >= 2
    end

    def message_id
      "<#{@revision}@#{self.class.host_name}>"
    end

    def headers
      [
        "X-Git-Author: #{@author_name}",
        "X-Git-Revision: #{@revision}",
        # "X-Git-Repository: #{path}",
        "X-Git-Repository: XXX",
        "X-Git-Commit-Id: #{@revision}",
        "Message-ID: #{message_id}"
      ]
    end

    def format_mail_subject
      affected_path_info = ""
      if @mailer.show_path?
        _affected_paths = affected_paths
        unless _affected_paths.empty?
          affected_path_info = " (#{_affected_paths.join(',')})"
        end
      end

      "[#{short_reference}#{affected_path_info}] " + subject
    end

    def format_mail_body_text
      TextMailBodyFormatter.new(self).format
    end

    def format_mail_body_html
      HTMLMailBodyFormatter.new(self).format
    end

    def short_revision
      GitCommitMailer.short_revision(@revision)
    end

    def file_index(name)
      @files.index(name)
    end

    def rss_title
      format_mail_subject
    end

    def rss_content
      "<pre>#{ERB::Util.h(format_mail_body_text)}</pre>"
    end

    private
    def sub_paths(prefix)
      prefixes = prefix.split(/\/+/)
      results = []
      @diffs.each do |diff|
        paths = diff.file_path.split(/\/+/)
        if prefixes.size < paths.size and prefixes == paths[0, prefixes.size]
          results << paths[prefixes.size]
        end
      end
      results
    end

    def affected_paths
      paths = []
      sub_paths = sub_paths('')
      paths.concat(sub_paths)
      paths.uniq
    end

    def set_records
      author_name, author_email, date, subject, parent_revisions =
        get_records(["%an", "%ae", "%at", "%s", "%P"])
      @author_name = author_name
      @author_email = author_email
      @date = Time.at(date.to_i)
      @subject = subject
      @parent_revisions = parent_revisions.split
      @summary = git("log -n 1 --pretty=format:%s%n%n%b #{@revision}")
    end

    def parse_diff
      output = git("log -n 1 --pretty=format:'' -C -p #{@revision}")
      output = force_utf8(output)
      output = output.lines.to_a
      output.shift # removes the first empty line

      @diffs = []
      lines = []

      line = output.shift
      lines << line.chomp if line # take out the very first 'diff --git' header
      while line = output.shift
        line.chomp!
        case line
        when /\Adiff --git/
          @diffs << create_file_diff(lines)
          lines = [line]
        else
          lines << line
        end
      end

      # create the last diff terminated by the EOF
      @diffs << create_file_diff(lines) if lines.length > 0
    end

    def create_file_diff(lines)
      diff = FileDiff.new(@mailer, lines, @revision)
      diff.index = @files.index(diff.file_path)
      diff
    end

    def parse_file_status
      git("log -n 1 --pretty=format:'' -C --name-status #{@revision}").
      lines.each do |line|
        line.rstrip!
        next if line.empty?
        case line
        when /\A([^\t]*?)\t([^\t]*?)\z/
          status = $1
          file = CommitInfo.unescape_file_path($2)

          case status
          when /^A/ # Added
            @added_files << file
          when /^M/ # Modified
            @updated_files << file
          when /^D/ # Deleted
            @deleted_files << file
          when /^T/ # File Type Changed
            @type_changed_files << file
          else
            raise "unsupported status type: #{line.inspect}"
          end

          @files << file
        when /\A([^\t]*?)\t([^\t]*?)\t([^\t]*?)\z/
          status = $1
          from_file = CommitInfo.unescape_file_path($2)
          to_file = CommitInfo.unescape_file_path($3)

          case status
          when /^R/ # Renamed
            @renamed_files << [from_file, to_file]
          when /^C/ # Copied
            @copied_files << [from_file, to_file]
          else
            raise "unsupported status type: #{line.inspect}"
          end

          @files << to_file
        else
          raise "unsupported status type: #{line.inspect}"
        end
      end
    end

    def force_utf8(string)
      if string.respond_to?(:valid_encoding?)
        string.force_encoding("UTF-8")
        return string if string.valid_encoding?
      end
      NKF.nkf("-w", string)
    end

    class FileDiff
      CHANGED_TYPE = {
        :added => "Added",
        :modified => "Modified",
        :deleted => "Deleted",
        :copied => "Copied",
        :renamed => "Renamed",
      }

      attr_reader :changes
      attr_accessor :index
      def initialize(mailer, lines, revision)
        @mailer = mailer
        @index = nil
        @body = ''
        @changes = []

        @type = :modified
        @is_binary = false
        @is_mode_changed = false

        @old_blob = @new_blob = nil

        parse_header(lines, revision)
        parse_extended_headers(lines)
        parse_body(lines)
      end

      def file_path
        @to_file
      end

      def format_header
        header = "  #{CHANGED_TYPE[@type]}: #{@to_file} "
        header << "(+#{@added_line} -#{@deleted_line})"
        header << "#{format_file_mode}#{format_similarity_index}\n"
        header << "  Mode: #{@old_mode} -> #{@new_mode}\n" if @is_mode_changed
        header << diff_separator
        header
      end

      def format
        formatted_diff = format_header

        if @mailer.add_diff?
          formatted_diff << headers + @body
        else
          formatted_diff << git_command
        end

        formatted_diff
      end

      private
      def extract_file_path(file_path)
        case CommitInfo.unescape_file_path(file_path)
        when /\A[ab]\/(.*)\z/
          $1
        else
          raise "unknown file path format: #{@to_file}"
        end
      end

      def parse_header(lines, revision)
        line = lines.shift
        if line =~ /\Adiff --git (.*) (.*)/
          @from_file = extract_file_path($1)
          @to_file = extract_file_path($2)
        else
          raise "Unexpected diff header format: #{line}"
        end
        @new_revision = revision
        @new_date = Time.at(@mailer.get_record(@new_revision, "%at").to_i)

        begin
          @old_revision = @mailer.parent_commit(revision)
          @old_date = Time.at(@mailer.get_record(@old_revision, "%at").to_i)
        rescue NoParentCommit
          @old_revision = '0' * 40
          @old_date = nil
        end
        # @old_revision = @mailer.parent_commit(revision)
      end

      def parse_ordinary_change(line)
        case line
        when /\A--- (a\/.*|"a\/.*"|\/dev\/null)\z/
          @minus_file = CommitInfo.unescape_file_path($1)
          @type = :added if $1 == '/dev/null'
        when /\A\+\+\+ (b\/.*|"b\/.*"|\/dev\/null)\z/
          @plus_file = CommitInfo.unescape_file_path($1)
          @type = :deleted if $1 == '/dev/null'
        when /\Aindex ([0-9a-f]{7,})\.\.([0-9a-f]{7,})/
          @old_blob = $1
          @new_blob = $2
        else
          return false
        end
        true
      end

      def parse_add_and_remove(line)
        case line
        when /\Anew file mode (.*)\z/
          @type = :added
          @new_file_mode = $1
        when /\Adeleted file mode (.*)\z/
          @type = :deleted
          @deleted_file_mode = $1
        else
          return false
        end
        true
      end

      def parse_copy_and_rename(line)
        case line
        when /\Arename (from|to) (.*)\z/
          @type = :renamed
        when /\Acopy (from|to) (.*)\z/
          @type = :copied
        when /\Asimilarity index (.*)%\z/
          @similarity_index = $1.to_i
        else
          return false
        end
        true
      end

      def parse_binary_file_change(line)
        if line =~ /\ABinary files (.*) and (.*) differ\z/
          @is_binary = true
          if $1 == '/dev/null'
            @type = :added
          elsif $2 == '/dev/null'
            @type = :deleted
          else
            @type = :modified
          end
          true
        else
          false
        end
      end

      def parse_mode_change(line)
        case line
        when /\Aold mode (.*)\z/
          @old_mode = $1
          @is_mode_changed = true
        when /\Anew mode (.*)\z/
          @new_mode = $1
          @is_mode_changed = true
        else
          return false
        end
        true
      end

      def parse_extended_headers(lines)
        line = lines.shift
        while line != nil and not line =~ /\A@@/
          is_parsed = false
          is_parsed ||= parse_ordinary_change(line)
          is_parsed ||= parse_add_and_remove(line)
          is_parsed ||= parse_copy_and_rename(line)
          is_parsed ||= parse_binary_file_change(line)
          is_parsed ||= parse_mode_change(line)
          unless is_parsed
            raise "unexpected extended line header: " + line
          end

          line = lines.shift
        end
        lines.unshift(line) if line
      end

      def parse_body(lines)
        @added_line = @deleted_line = 0
        from_offset = 0
        to_offset = 0
        line = lines.shift
        while line != nil
          case line
          when /\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)?/
            from_offset = $1.to_i
            to_offset = $2.to_i
            @changes << [:hunk_header, [from_offset, to_offset], line]
          when /\A\+/
            @added_line += 1
            @changes << [:added, to_offset, line]
            to_offset += 1
          when /\A\-/
            @deleted_line += 1
            @changes << [:deleted, from_offset, line]
            from_offset += 1
          else
            @changes << [:not_changed, [from_offset, to_offset], line]
            from_offset += 1
            to_offset += 1
          end

          @body << line + "\n"
          line = lines.shift
        end
      end

      def format_date(date)
        date.strftime('%Y-%m-%d %X %z')
      end

      def format_old_date
        format_date(@old_date)
      end

      def format_new_date
        format_date(@new_date)
      end

      def short_old_revision
        GitCommitMailer.short_revision(@old_revision)
      end

      def short_new_revision
        GitCommitMailer.short_revision(@new_revision)
      end

      def format_blob(blob)
        if blob
          " (#{blob})"
        else
          ""
        end
      end

      def format_new_blob
        format_blob(@new_blob)
      end

      def format_old_blob
        format_blob(@old_blob)
      end

      def format_old_date_and_blob
        format_old_date + format_old_blob
      end

      def format_new_date_and_blob
        format_new_date + format_new_blob
      end

      def from_header
        "--- #{@from_file}    #{format_old_date_and_blob}\n"
      end

      def to_header
        "+++ #{@to_file}    #{format_new_date_and_blob}\n"
      end

      def headers
         unless @is_binary
           if (@type == :renamed || @type == :copied) && @similarity_index == 100
             return ""
           end

           case @type
           when :added
             "--- /dev/null\n" + to_header
           when :deleted
             from_header + "+++ /dev/null\n"
           else
             from_header + to_header
           end
         else
           "(Binary files differ)\n"
         end
      end

      def git_command
        case @type
        when :added
          command = "show"
          args = ["#{short_new_revision}:#{@to_file}"]
        when :deleted
          command = "show"
          args = ["#{short_old_revision}:#{@to_file}"]
        when :modified
          command = "diff"
          args = [short_old_revision, short_new_revision, "--", @to_file]
        when :renamed
          command = "diff"
          args = ["-C", "--diff-filter=R",
                  short_old_revision, short_new_revision, "--",
                  @from_file, @to_file]
        when :copied
          command = "diff"
          args = ["-C", "--diff-filter=C",
                  short_old_revision, short_new_revision, "--",
                  @from_file, @to_file]
        else
          raise "unknown diff type: #{@type}"
        end

        command += " #{args.join(' ')}" unless args.empty?
        "    % git #{command}\n"
      end

      def format_file_mode
        case @type
        when :added
          " #{@new_file_mode}"
        when :deleted
          " #{@deleted_file_mode}"
        else
          ""
        end
      end

      def format_similarity_index
        if @type == :renamed or @type == :copied
          " #{@similarity_index}%"
        else
          ""
        end
      end

      def diff_separator
        "#{"=" * 67}\n"
      end
    end

    class MailBodyFormatter
      def initialize(info)
        @info = info
        @mailer = @info.mailer
      end

      def format
        ERB.new(template, nil, "<>").result(binding)
      end

      private
      def commit_url
        case @mailer.repository_browser
        when :github
          user = @mailer.github_user
          repository = @mailer.github_repository
          return nil if user.nil? or repository.nil?
          base_url = @mailer.github_base_url
          revision = @info.revision
          "#{base_url}/#{user}/#{repository}/commit/#{revision}"
        else
          nil
        end
      end

      def commit_file_url(file)
        base_url = commit_url
        return nil if base_url.nil?

        case @mailer.repository_browser
        when :github
          index = @info.file_index(file)
          return nil if index.nil?
          "#{base_url}#diff-#{index}"
        else
          nil
        end
      end

      def commit_file_line_number_url(file, direction, line_number)
        base_url = commit_url
        return nil if base_url.nil?

        case @mailer.repository_browser
        when :github
          index = @info.file_index(file)
          return nil if index.nil?
          url = "#{base_url}#L#{index}"
          url << ((direction == :from) ? "L" : "R")
          url << line_number.to_s
          url
        else
          nil
        end
      end
    end

    class TextMailBodyFormatter < MailBodyFormatter
      def format
        super.sub(/\n+\z/, "\n")
      end

      private
      def template
        <<-EOT
<%= @info.author_name %>\t<%= @mailer.format_time(@info.date) %>


  New Revision: <%= @info.revision %>
<%= format_commit_url %>

<% unless @info.merge_status.empty? %>
<%   @info.merge_status.each do |status| %>
  <%= status %>
<%   end %>

<% end %>
  Message:
<% @info.summary.rstrip.each_line do |line| %>
    <%= line.rstrip %>
<% end %>

<%= format_files("Added",        @info.added_files) %>
<%= format_files("Copied",       @info.copied_files) %>
<%= format_files("Removed",      @info.deleted_files) %>
<%= format_files("Modified",     @info.updated_files) %>
<%= format_files("Renamed",      @info.renamed_files) %>
<%= format_files("Type Changed", @info.type_changed_files) %>

<%= format_diff %>
EOT
      end

      def format_commit_url
        url = commit_url
        return "" if url.nil?
        "  #{url}\n"
      end

      def format_files(title, items)
        return "" if items.empty?

        formatted_files = "  #{title} files:\n"
        items.each do |item_name, new_item_name|
          if new_item_name.nil?
            formatted_files << "    #{item_name}\n"
          else
            formatted_files << "    #{new_item_name}\n"
            formatted_files << "      (from #{item_name})\n"
          end
        end
        formatted_files
      end

      def format_diff
        format_diffs.join("\n")
      end

      def format_diffs
        @info.diffs.collect do |diff|
          diff.format
        end
      end
    end

    class HTMLMailBodyFormatter < MailBodyFormatter
      include ERB::Util

      def format
        @indent_level = 0
        super
      end

      private
      def template
        <<-EOT
<!DOCTYPE html>
<html>
  <head>
  </head>
  <body>
    <%= dl_start %>
      <%= dt("Author") %>
      <%= dd(h("\#{@info.author_name} <\#{@info.author_email}>")) %>
      <%= dt("Date") %>
      <%= dd(h(@mailer.format_time(@info.date))) %>
      <%= dt("New Revision") %>
      <%= dd(format_revision) %>
<% unless @info.merge_status.empty? %>
      <%= dt("Merge") %>
      <%= dd_start %>
        <ul>
<%   @info.merge_status.each do |status| %>
          <li><%= h(status) %></li>
<%   end %>
        </ul>
      </dd>
<% end %>
      <%= dt("Message") %>
      <%= dd(pre(h(@info.summary.strip))) %>
<%= format_files("Added",        @info.added_files) %>
<%= format_files("Copied",       @info.copied_files) %>
<%= format_files("Removed",      @info.deleted_files) %>
<%= format_files("Modified",     @info.updated_files) %>
<%= format_files("Renamed",      @info.renamed_files) %>
<%= format_files("Type Changed", @info.type_changed_files) %>
    </dl>

<%= format_diffs %>
  </body>
</html>
EOT
      end

      def format_revision
        revision = @info.revision
        url = commit_url
        if url
          formatted_revision = "<a href=\"#{h(url)}\">#{h(revision)}</a>"
        else
          formatted_revision = h(revision)
        end
        formatted_revision
      end

      def format_files(title, items)
        return "" if items.empty?

        formatted_files = ""
        formatted_files << "      #{dt(h(title) + ' files')}\n"
        formatted_files << "      #{dd_start}\n"
        formatted_files << "        <ul>\n"
        items.each do |item_name, new_item_name|
          if new_item_name.nil?
            formatted_files << "          <li>#{format_file(item_name)}</li>\n"
          else
            formatted_files << "          <li>\n"
            formatted_files << "            #{format_file(new_item_name)}<br>\n"
            formatted_files << "            (from #{item_name})\n"
            formatted_files << "          </li>\n"
          end
        end
        formatted_files << "        </ul>\n"
        formatted_files << "      </dd>\n"
        formatted_files
      end

      def format_file(file)
        content = h(file)
        url = commit_file_url(file)
        if url
          content = tag("a", {"href" => url}, content)
        end
        content
      end

      def format_diffs
        return "" if @info.diffs.empty?

        formatted_diff = ""
        formatted_diff << "    #{div_diff_section_start}\n"
        @indent_level = 3
        @info.diffs.each do |diff|
          formatted_diff << "#{format_diff(diff)}\n"
        end
        formatted_diff << "    </div>\n"
        formatted_diff
      end

      def format_diff(diff)
        header_column = format_header_column(diff)
        from_line_column, to_line_column, content_column =
          format_body_columns(diff)

        table_diff do
          head = tag("thead") do
            tr_diff_header do
              tag("td", {"colspan" => "3"}) do
                pre_column(header_column)
              end
            end
          end

          body = tag("tbody") do
            tag("tr") do
              [
                th_diff_line_number {pre_column(from_line_column)},
                th_diff_line_number {pre_column(to_line_column)},
                td_diff_content     {pre_column(content_column)},
              ]
            end
          end

          [head, body]
        end
      end

      def format_header_column(diff)
        header_column = ""
        diff.format_header.each_line do |line|
          line = line.chomp
          case line
          when /^=/
            header_column << span_diff_header_mark(h(line))
          else
            header_column << span_diff_header(h(line))
          end
          header_column << "\n"
        end
        header_column
      end

      def format_body_columns(diff)
        from_line_column = ""
        to_line_column = ""
        content_column = ""
        file_path = diff.file_path
        diff.changes.each do |type, line_number, line|
          case type
          when :hunk_header
            from_line_number, to_line_number = line_number
            from_line_column << span_line_number_hunk_header(file_path, :from,
                                                             from_line_number)
            to_line_column << span_line_number_hunk_header(file_path, :to,
                                                           to_line_number)
            case line
            when /\A(@@[\s0-9\-+,]+@@\s*)(.+)(\s*)\z/
              hunk_info = $1
              context = $2
              formatted_line = h(hunk_info) + span_diff_context(h(context))
            else
              formatted_line = h(line)
            end
            content_column << span_diff_hunk_header(formatted_line)
          when :added
            from_line_column << span_line_number_nothing
            to_line_column << span_line_number_added(file_path, line_number)
            content_column << span_diff_added(h(line))
          when :deleted
            from_line_column << span_line_number_deleted(file_path, line_number)
            to_line_column << span_line_number_nothing
            content_column << span_diff_deleted(h(line))
          when :not_changed
            from_line_number, to_line_number = line_number
            from_line_column << span_line_number_not_changed(file_path, :from,
                                                             from_line_number)
            to_line_column << span_line_number_not_changed(file_path, :to,
                                                           to_line_number)
            content_column << span_diff_not_changed(h(line))
          end
          from_line_column << "\n"
          to_line_column << "\n"
          content_column << "\n"
        end
        [from_line_column, to_line_column, content_column]
      end

      def tag_start(name, attributes)
        start_tag = "<#{name}"
        unless attributes.empty?
          sorted_attributes = attributes.sort_by do |key, value|
            key
          end
          formatted_attributes = sorted_attributes.collect do |key, value|
            if value.is_a?(Hash)
              sorted_value = value.sort_by do |value_key, value_value|
                value_key
              end
              value = sorted_value.collect do |value_key, value_value|
                "#{value_key}: #{value_value}"
              end
            end
            if value.is_a?(Array)
              value = value.sort.join("; ")
            end
            "#{h(key)}=\"#{h(value)}\""
          end
          formatted_attributes = formatted_attributes.join(" ")
          start_tag << " #{formatted_attributes}"
        end
        start_tag << ">"
        start_tag
      end

      def tag(name, attributes={}, content=nil, &block)
        block_used = false
        if content.nil? and block_given?
          @indent_level += 1
          if block.arity == 1
            content = []
            yield(content)
          else
            content = yield
          end
          @indent_level -= 1
          block_used = true
        end
        content ||= ""
        if content.is_a?(Array)
          if block_used
            separator = "\n"
          else
            separator = ""
          end
          content = content.join(separator)
        end

        formatted_tag = ""
        formatted_tag << "  " * @indent_level if block_used
        formatted_tag << tag_start(name, attributes)
        formatted_tag << "\n" if block_used
        formatted_tag << content
        formatted_tag << "\n" + ("  " * @indent_level) if block_used
        formatted_tag << "</#{name}>"
        formatted_tag
      end

      def dl_start
        tag_start("dl",
                  "style" => {
                    "margin-left" => "2em",
                    "line-height" => "1.5",
                  })
      end

      def dt_margin
        8
      end

      def dt(content)
        tag("dt",
            {
              "style" => {
                "clear"       => "both",
                "float"       => "left",
                "width"       => "#{dt_margin}em",
                "font-weight" => "bold",
              },
            },
            content)
      end

      def dd_start
        tag_start("dd",
                  "style" => {
                    "margin-left" => "#{dt_margin + 0.5}em",
                  })
      end

      def dd(content)
        "#{dd_start}#{content}</dd>"
      end

      def border_styles
        {
          "border"      => "1px solid #aaa",
        }
      end

      def pre(content, styles={})
        font_families = [
          "Consolas", "Menlo", "\"Liberation Mono\"",
          "Courier", "monospace"
        ]
        pre_styles = {
          "font-family" => font_families.join(", "),
          "line-height" => "1.2",
          "padding"     => "0.5em",
          "width"       => "auto",
        }
        pre_styles = pre_styles.merge(border_styles)
        tag("pre", {"style" => pre_styles.merge(styles)}, content)
      end

      def div_diff_section_start
        tag_start("div",
                  "class" => "diff-section",
                  "style" => {
                    "clear" => "both",
                  })
      end

      def div_diff_start
        tag_start("div",
                  "class" => "diff",
                  "style" => {
                    "margin-left"  => "1em",
                    "margin-right" => "1em",
                  })
      end

      def table_diff(&block)
        styles = {
          "border-collapse" => "collapse",
        }
        tag("table",
            {
              "style" => border_styles.merge(styles),
            },
            &block)
      end

      def tr_diff_header(&block)
        tag("tr",
            {
              "class" => "diff-header",
              "style" => border_styles,
            },
            &block)
      end

      def th_diff_line_number(&block)
        tag("th",
            {
              "class" => "diff-line-number",
              "style" => border_styles,
            },
            &block)
      end

      def td_diff_content(&block)
        tag("td",
            {
              "class" => "diff-content",
              "style" => border_styles,
            },
            &block)
      end

      def pre_column(column)
        pre(column,
            "white-space" => "normal",
            "margin" => "0",
            "border" => "0")
      end

      def span_common_styles
        {
          "white-space" => "pre",
          "display"     => "block",
        }
      end

      def span_context_styles
        {
          "background-color" => "#ffffaa",
          "color"            => "#000000",
        }
      end

      def span_deleted_styles
        {
          "background-color" => "#ffaaaa",
          "color"            => "#000000",
        }
      end

      def span_added_styles
        {
          "background-color" => "#aaffaa",
          "color"            => "#000000",
        }
      end

      def span_line_number_styles
        span_common_styles
      end

      def span_line_number_nothing
        tag("span",
            {
              "class" => "diff-line-number-nothing",
              "style" => span_line_number_styles,
            },
            "&nbsp;")
      end

      def span_line_number_hunk_header(file_path, direction, offset)
        content = "..."
        url = commit_file_line_number_url(file_path, direction, offset - 1)
        if url
          content = tag("a", {"href" => url}, content)
        end
        tag("span",
            {
              "class" => "diff-line-number-hunk-header",
              "style" => span_line_number_styles,
            },
            content)
      end

      def span_line_number_deleted(file_path, line_number)
        content = h(line_number.to_s)
        url = commit_file_line_number_url(file_path, :from, line_number)
        if url
          content = tag("a", {"href" => url}, content)
        end
        tag("span",
            {
              "class" => "diff-line-number-deleted",
              "style" => span_line_number_styles.merge(span_deleted_styles),
            },
            content)
      end

      def span_line_number_added(file_path, line_number)
        content = h(line_number.to_s)
        url = commit_file_line_number_url(file_path, :to, line_number)
        if url
          content = tag("a", {"href" => url}, content)
        end
        tag("span",
            {
              "class" => "diff-line-number-added",
              "style" => span_line_number_styles.merge(span_added_styles),
            },
            content)
      end

      def span_line_number_not_changed(file_path, direction, line_number)
        content = h(line_number.to_s)
        url = commit_file_line_number_url(file_path, direction, line_number)
        if url
          content = tag("a", {"href" => url}, content)
        end
        tag("span",
            {
              "class" => "diff-line-number-not-changed",
              "style" => span_line_number_styles,
            },
            content)
      end

      def span_diff_styles
        span_common_styles
      end

      def span_diff_metadata_styles
        styles = {
          "background-color" => "#eaf2f5",
          "color"            => "#999999",
        }
        span_diff_styles.merge(styles)
      end

      def span_diff_header(content)
        tag("span",
            {
              "class" => "diff-header",
              "style" => span_diff_metadata_styles,
            },
            content)
      end

      def span_diff_header_mark(content)
        tag("span",
            {
              "class" => "diff-header-mark",
              "style" => span_diff_metadata_styles,
            },
            content)
      end

      def span_diff_hunk_header(content)
        tag("span",
            {
              "class" => "diff-hunk-header",
              "style" => span_diff_metadata_styles,
            },
            content)
      end

      def span_diff_context(content)
        tag("span",
            {
              "class" => "diff-context",
              "style" => span_context_styles,
            },
            content)
      end

      def span_diff_deleted(content)
        tag("span",
            {
              "class" => "diff-deleted",
              "style" => span_diff_styles.merge(span_deleted_styles),
            },
            content)
      end

      def span_diff_added(content)
        tag("span",
            {
              "class" => "diff-added",
              "style" => span_diff_styles.merge(span_added_styles),
            },
            content)
      end

      def span_diff_not_changed(content)
        tag("span",
            {
              "class" => "diff-not-changed",
              "style" => span_diff_styles,
            },
            content)
      end
    end
  end
end

if __FILE__ == $0
  begin
    argv = []
    processing_change = nil

    found_include_option = false
    ARGV.each do |arg|
      if found_include_option
        $LOAD_PATH.unshift(arg)
        found_include_option = false
      else
        case arg
        when "-I", "--include"
          found_include_option = true
        when /\A-I/, /\A--include=?/
          path = $POSTMATCH
          $LOAD_PATH.unshift(path) unless path.empty?
        else
          argv << arg
        end
      end
    end

    mailer = GitCommitMailer.parse_options_and_create(argv)

    if not mailer.track_remote?
      running = SpentTime.new("running the whole command")
      running.spend do
        while line = STDIN.gets
          old_revision, new_revision, reference = line.split
          processing_change = [old_revision, new_revision, reference]
          mailer.process_reference_change(old_revision, new_revision, reference)
          mailer.send_all_mails
        end
      end

      if mailer.verbose?
        $executing_git.report
        $sending_mail.report
        running.report
      end
    else
      reference_changes = mailer.fetch
      reference_changes.each do |old_revision, new_revision, reference|
        processing_change = [old_revision, new_revision, reference]
        mailer.process_reference_change(old_revision, new_revision, reference)
        mailer.send_all_mails
      end
    end
  rescue Exception => error
    require 'net/smtp'
    require 'socket'
    require 'etc'

    to = []
    subject = "Error"
    user = Etc.getpwuid(Process.uid).name
    from = "#{user}@#{Socket.gethostname}"
    sender = nil
    server = nil
    port = nil
    begin
      to, options = GitCommitMailer.parse(argv)
      to = options.error_to unless options.error_to.empty?
      from = options.from || from
      sender = options.sender
      subject = "#{options.name}: #{subject}" if options.name
      server = options.server
      port = options.port
    rescue OptionParser::MissingArgument
      argv.delete_if {|argument| $!.args.include?(argument)}
      retry
    rescue OptionParser::ParseError
      if to.empty?
        _to, *_ = ARGV.reject {|argument| /^-/.match(argument)}
        to = [_to]
      end
    end

    detail = <<-EOM
Processing change: #{processing_change.inspect}

#{error.class}: #{error.message}
#{error.backtrace.join("\n")}
  EOM
    to = to.compact
    if to.empty?
      STDERR.puts detail
    else
      from = GitCommitMailer.extract_email_address(from)
      to = to.collect {|address| GitCommitMailer.extract_email_address(address)}
      header = <<-HEADER
X-Mailer: #{GitCommitMailer.x_mailer}
MIME-Version: 1.0
Content-Type: text/plain; charset=us-ascii
Content-Transfer-Encoding: 7bit
From: #{from}
To: #{to.join(', ')}
Subject: #{subject}
Date: #{Time.now.rfc2822}
HEADER
      header << "Sender: #{sender}\n" if sender
      mail = <<-MAIL
#{header}

#{detail}
MAIL
      GitCommitMailer.send_mail(server || "localhost", port,
                                sender || from, to, mail)
      exit(false)
    end
  end
end
