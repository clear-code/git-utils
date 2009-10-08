#!/usr/bin/env ruby
#
# Copyright (C) 2009  Ryo Onodera <onodera@clear-code.com>
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

#### An explanation for the complicated command used in GitCommitMailer#
#### process_create_branch and GitCommitMailer#process_update_branch
#
# Basically, that command shows all log entries that are not already covered by
# another ref - i.e. commits that are now accessible from this
# ref that were previously not accessible
#
# Consider this:
#   1 --- 2 --- O --- X --- 3 --- 4 --- N
#
# O is $old_revision for $refname
# N is $new_revision for $refname
# X is a revision pointed to by some other ref, for which we may
#   assume that an email has already been generated.
# In this case we want to issue an email containing only revisions
# 3, 4, and N.  Given (almost) by
#
#  git rev-list N ^O --not --all
#
# The reason for the "almost", is that the "--not --all" will take
# precedence over the "N", and effectively will translate to
#
#  git rev-list N ^O ^X ^N
#
# So, we need to build up the list more carefully.  git rev-parse
# will generate a list of revs that may be fed into git rev-list.
# We can get it to make the "--not --all" part and then filter out
# the "^N" with:
#
#  git rev-parse --not --all | grep -v N
#
# Then, using the --stdin switch to git rev-list we have effectively
# manufactured
#
#  git rev-list N ^O ^X
#
# This leaves a problem when someone else updates the repository
# while this script is running.  Their new value of the ref we're
# working on would be included in the "--not --all" output; and as
# our $new_revision would be an ancestor of that commit, it would exclude
# all of our commits.  What we really want is to exclude the current
# value of $refname from the --not list, rather than N itself.  So:
#
#  git rev-parse --not --all | grep -v $(git rev-parse $refname)
#
# Get's us to something pretty safe (apart from the small time
# between refname being read, and git rev-parse running - for that,
# I give up)
#
#
# Next problem, consider this:
#   * --- B --- * --- O ($old_revision)
#          \
#           * --- X --- * --- N ($new_revision)
#
# That is to say, there is no guarantee that old_revision is a strict
# subset of new_revision (it would have required a --force, but that's
# allowed).  So, we can't simply say rev-list $old_revision..$new_revision.
# Instead we find the common base of the two revs and list from
# there.
#
# As above, we need to take into account the presence of X; if
# another branch is already in the repository and points at some of
# the revisions that we are about to output - we don't want them.
# The solution is as before: git rev-parse output filtered.
#
# Finally, tags: 1 --- 2 --- O --- T --- 3 --- 4 --- N
#
# Tags pushed into the repository generate nice shortlog emails that
# summarise the commits between them and the previous tag.  However,
# those emails don't include the full commit messages that we output
# for a branch update.  Therefore we still want to output revisions
# that have been output on a tag email.
#
# Luckily, git rev-parse includes just the tool.  Instead of using
# "--all" we use "--branches"; this has the added benefit that
# "remotes/" will be ignored as well.

require 'English'
require "optparse"
require "ostruct"
require "time"
require "net/smtp"
require "socket"
require "nkf"

original_argv = ARGV.dup
argv = []

found_include_option = false
while (arg = original_argv.shift)
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

def extract_email_address(address)
  if /<(.+?)>/ =~ address
    $1
  else
    address
  end
end

def sendmail(to, from, mail, server=nil, port=nil)
  server ||= "localhost"
  from = extract_email_address(from)
  to = to.collect {|address| extract_email_address(address)}
  Net::SMTP.start(server, port) do |smtp|
    smtp.open_message_stream(from, to) do |f|
      f.print(mail)
    end
  end
end

class GitCommitMailer
  KILO_SIZE = 1000
  DEFAULT_MAX_SIZE = "100M"

  class Info
    def Info.get_record(revision, record)
      GitCommitMailer.get_record(revision, record)
    end

    def get_record(record)
      Info.get_record(@revision, record)
    end

    def short_reference
       @reference.sub(/\A.*\/.*\//,'');
    end
  end

  class PushInfo < Info
    attr_reader :old_revision, :new_revision, :reference, :reference_type, :log
    attr_reader :author, :author_email, :date, :subject, :change_type
    def initialize(old_revision, new_revision, reference,
                   reference_type, change_type, log)
      @old_revision = old_revision
      @new_revision = new_revision
      @reference = reference
      @reference_type = reference_type
      @log = log
      @author = get_record("%an")
      @author_email = get_record("%an <%ae>")
      @date = Time.at(get_record("%at").to_i)
      @change_type = change_type
    end

    def revision
      @new_revision
    end

    def headers
      [ "X-Git-OldRev: #{old_revision}",
        "X-Git-NewRev: #{new_revision}",
        "X-Git-Refname: #{reference}",
        "X-Git-Reftype: #{reference_type}" ]
    end

    CHANGE_TYPE = {
      :create => "created",
      :update => "updated",
      :delete => "deleted",
    }
  end

  class CommitInfo < Info
    class DiffPerFile
      attr_reader :old_revision, :new_revision, :from_file, :to_file
      attr_reader :added_line, :deleted_line, :body, :type
      attr_reader :deleted_file_mode, :new_file_mode, :old_mode, :new_mode
      attr_reader :similarity_index
      def initialize(lines, revision)
        @metadata = []
        @body = ''

        parse_header(lines, revision)
        parse_extended_headers(lines)
        parse_body(lines)
      end

      def parse_header(lines, revision)
        line = lines.shift
        if line =~ /\Adiff --git a\/(.*) b\/(.*)/
          @from_file = $1
          @to_file = $2
        else
          raise "Corrupted diff header"
        end
        @new_revision = revision
        @old_revision = `git log -n 1 --pretty=format:%H #{revision}~`.strip
        #@old_revision = `git rev-parse #{revision}~`.strip

        @new_date = Time.at(Info.get_record(@new_revision, "%at").to_i)
        @old_date = Time.at(Info.get_record(@old_revision, "%at").to_i)
      end

      def mode_changed?
        @is_mode_changed
      end

      def parse_extended_headers(lines)
        @type = :modified
        @is_binary = false
        @is_mode_changed = false

        line = lines.shift
        while line != nil and not line =~ /\A@@/
          case line
          when /\A--- (a\/.*|\/dev\/null)\z/
            @minus_file = $1
            @type = :added if $1 == '/dev/null'
          when /\A\+\+\+ (b\/.*|\/dev\/null)\z/
            @plus_file = $1
            @type = :deleted if $1 == '/dev/null'
          when /\Anew file mode (.*)\z/
            @type = :added
            @new_file_mode = $1
          when /\Adeleted file mode (.*)\z/
            @type = :deleted
            @deleted_file_mode = $1
          when /\ABinary files (.*) and (.*) differ\z/
            @is_binary = true
            if $1 == '/dev/null'
              @type = :added
            elsif $2 == '/dev/null'
              @type = :deleted
            else
              @type = :modified
            end
          when /\Aindex ([0-9a-f]{7})\.\.([0-9a-f]{7})/
            @old_blob = $1
            @new_blob = $2
          when /\Arename (from|to) (.*)\z/
            @type = :renamed
          when /\Acopy (from|to) (.*)\z/
            @type = :copied
          when /\Asimilarity index (.*)%\z/
            @similarity_index = $1.to_i
          when /\Aold mode (.*)\z/
            @old_mode = $1
            @is_mode_changed = true
          when /\Anew mode (.*)\z/
            @new_mode = $1
            @is_mode_changed = true
          else
            puts "needs to parse: " + line
            @metadata << line #need to parse
          end

          line = lines.shift
        end
        lines.unshift(line) if line
      end

      def parse_body(lines)
        @added_line = @deleted_line = 0
        line = lines.shift
        while line != nil
          if line =~ /\A\+/
            @added_line += 1
          elsif line =~ /\A\-/
            @deleted_line += 1
          end

          @body << line + "\n"
          line = lines.shift
        end
      end

      def format_time(time)
        time.strftime('%Y-%m-%d %X %z')
      end

      def short_old_revision
        GitCommitMailer.short_revision(@old_revision)
      end

      def short_new_revision
        GitCommitMailer.short_revision(@new_revision)
      end

      def header
         unless @is_binary
           if @similarity_index == 100 && (@type == :renamed || @type == :copied)
             return ""
           end

           case @type
           when :added
             "--- /dev/null\n" +
             "+++ #{@to_file}    #{format_time(@new_date)} (#{@new_blob})\n"
           when :deleted
             "--- #{@from_file}    #{format_time(@old_date)} (#{@old_blob})\n" +
             "+++ /dev/null\n"
           else
             "--- #{@from_file}    #{format_time(@old_date)} (#{@old_blob})\n" +
             "+++ #{@to_file}    #{format_time(@new_date)} (#{@new_blob})\n"
           end
         else
           "(Binary files differ)\n"
         end
      end

      def value
         header + body
      end

      def file
        @to_file # the new file entity when copied and renamed
      end

      def link
        file
      end

      def file_path
        file
      end
    end

    attr_reader :repository, :revision
    attr_reader :author, :date, :subject, :log, :commit_id
    attr_reader :author_email, :diffs, :added_files, :copied_files
    attr_reader :deleted_files, :updated_files, :renamed_files
    attr_accessor :reference, :merge_status
    def initialize(repository, reference, revision)
      @repository = repository
      @reference = reference
      @revision = revision

      @added_files = []
      @copied_files = []
      @deleted_files = []
      @updated_files = []
      @renamed_files = []

      initialize_by_getting_records
      parse_diff
      parse_file_status

      @merge_status = []
    end

    def short_revision
      GitCommitMailer.short_revision(@revision)
    end

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

    def initialize_by_getting_records
      @author = get_record("%an")
      @author_email = get_record("%an <%ae>")
      @date = Time.at(get_record("%at").to_i)
      @subject = get_record("%s")
      @log = `git log -n 1 --pretty=format:%s%n%n%b #{@revision}`
      @commit_id = get_record("%H")
      @parent_revisions = get_record("%P").split
    end

    def parse_diff
      f = IO.popen("git log -n 1 --pretty=format:'' -C -p #{@revision}")
      f.gets #removes the first empty line

      #f = IO.popen("git diff #{revision}~ #{revision}")

      @diffs = []
      lines = []

      line = f.gets
      lines << line.chomp if line #take out the very first 'diff --git' header
      while line = f.gets
        line.chomp!
        if line =~ /\Adiff --git/
          @diffs << DiffPerFile.new(lines, @revision)
          lines = [line]
        else
          lines << line
        end
      end

      #create the last diff terminated by the EOF
      @diffs << DiffPerFile.new(lines, @revision) if lines.length > 0
    end

    def parse_file_status
      `git log -n 1 --pretty=format:'' -C --name-status #{@revision}`.
      lines.each do |line|
        line.rstrip!
        if line =~ /\A([^\t]*?)\t([^\t]*?)\z/
          status = $1
          file = $2

          case status
          when /^A/ # Added
            @added_files << file
          when /^M/ # Modified
            @updated_files << file
          when /^D/ # Deleted
            @deleted_files << file
          end
        elsif line =~ /\A([^\t]*?)\t([^\t]*?)\t([^\t]*?)\z/
          status = $1
          from_file = $2
          to_file = $3

          case status
          when /^R/ # Renamed
            @renamed_files << [from_file, to_file]
          when /^C/ # Copied
            @copied_files << [from_file, to_file]
          end
        end
      end
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

    def headers
      [ "X-Git-Author: #{author}",
        "X-Git-Revision: #{revision}",
        # "X-Git-Repository: #{path}",
        "X-Git-Repository: XXX",
        "X-Git-Commit-Id: #{commit_id}" ]
    end
  end

  class << self
    def get_record(revision, record)
      `git log -n 1 --pretty=format:'#{record}' #{revision}`.strip
    end

    def short_revision(revision)
      revision[0,7]
    end

    def parse_options_and_create(argv=nil)
      argv ||= ARGV
      to, options = parse(argv)
      to = [to, *options.to].compact
      mailer = new(to)
      apply_options(mailer, options)
      mailer
    end

    def parse(argv)
      options = make_options

      parser = make_parser(options)
      argv = argv.dup
      parser.parse!(argv)
      to, *rest = argv

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
      ENV['GIT_DIR'] = options.repository
      #puts "@@@@@@@setting GIT_DIR to #{options.repository}"
      #mailer.reference = options.reference
      mailer.from = options.from
      mailer.from_domain = options.from_domain
      mailer.add_diff = options.add_diff
      mailer.max_size = options.max_size
      mailer.repository_uri = options.repository_uri
      mailer.rss_path = options.rss_path
      mailer.rss_uri = options.rss_uri
      mailer.show_path = options.show_path
      mailer.send_push_mail = options.send_push_mail
      mailer.name = options.name
      mailer.use_utf7 = options.use_utf7
      mailer.server = options.server
      mailer.port = options.port
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
      options.to = []
      options.error_to = []
      options.from = nil
      options.from_domain = nil
      options.add_diff = true
      options.max_size = parse_size(DEFAULT_MAX_SIZE)
      options.repository_uri = nil
      options.rss_path = nil
      options.rss_uri = nil
      options.show_path = false
      options.send_push_mail = false
      options.name = nil
      options.use_utf7 = false
      options.server = "localhost"
      options.port = Net::SMTP.default_port
      options
    end

    def make_parser(options)
      OptionParser.new do |opts|
        opts.banner += "TO"

        add_repository_options(opts, options)
        add_email_options(opts, options)
        add_input_options(opts, options)
        add_rss_options(opts, options)
        add_other_options(opts, options)

        opts.on_tail("--help", "Show this message") do
          puts opts
          exit!
        end
      end
    end

    def add_repository_options(opts, options)
      opts.separator ""
      opts.separator "Repository related options:"

      opts.on("--repository=PATH",
              "Use PATH as the target git repository",
              "(#{options.repository})") do |path|
        options.repository = path
      end

      opts.on("--reference=REFERENCE",
              "Use REFERENCE as the target reference",
              "(#{options.reference})") do |reference|
        options.reference = reference
      end
    end

    def add_email_options(opts, options)
      opts.separator ""
      opts.separator "E-mail related options:"

      opts.on("-sSERVER", "--server=SERVER",
              "Use SERVER as SMTP server (#{options.server})") do |server|
        options.server = server
      end

      opts.on("-pPORT", "--port=PORT", Integer,
              "Use PORT as SMTP port (#{options.port})") do |port|
        options.port = port
      end

      opts.on("-tTO", "--to=TO", "Add TO to To: address") do |to|
        options.to << to unless to.nil?
      end

      opts.on("-eTO", "--error-to=TO",
              "Add TO to To: address when an error occurs") do |to|
        options.error_to << to unless to.nil?
      end

      opts.on("-fFROM", "--from=FROM", "Use FROM as from address") do |from|
        if options.from_domain
          raise OptionParser::CannotCoexistOption,
                  "cannot coexist with --from-domain"
        end
        options.from = from
      end

      opts.on("--from-domain=DOMAIN",
              "Use author@DOMAIN as from address") do |domain|
        if options.from
          raise OptionParser::CannotCoexistOption,
                  "cannot coexist with --from"
        end
        options.from_domain = domain
      end
    end

    def add_input_options(opts, options)
      opts.separator ""
      opts.separator "Output related options:"

      opts.on("--name=NAME", "Use NAME as repository name") do |name|
        options.name = name
      end

      opts.on("--[no-]show-path",
              "Show commit target path") do |bool|
        options.show_path = bool
      end

      opts.on("--[no-]send-push-mail",
              "Send push mail") do |bool|
        options.send_push_mail = bool
      end

      opts.on("--repository-uri=URI",
              "Use URI as URI of repository") do |uri|
        options.repository_uri = uri
      end

      opts.on("-n", "--no-diff", "Don't add diffs") do |diff|
        options.add_diff = false
      end

      opts.on("--max-size=SIZE",
              "Limit mail body size to SIZE",
              "G/GB/M/MB/K/KB/B units are available",
              "(#{format_size(options.max_size)})") do |max_size|
        begin
          options.max_size = parse_size(max_size)
        rescue ArgumentError
          raise OptionParser::InvalidArgument, max_size
        end
      end

      opts.on("--no-limit-size",
              "Don't limit mail body size",
              "(#{options.max_size.nil?})") do |not_limit_size|
        options.max_size = nil
      end

      opts.on("--[no-]utf7",
              "Use UTF-7 encoding for mail body instead",
              "of UTF-8 (#{options.use_utf7})") do |use_utf7|
        options.use_utf7 = use_utf7
      end
    end

    def add_rss_options(opts, options)
      opts.separator ""
      opts.separator "RSS related options:"

      opts.on("--rss-path=PATH", "Use PATH as output RSS path") do |path|
        options.rss_path = path
      end

      opts.on("--rss-uri=URI", "Use URI as output RSS URI") do |uri|
        options.rss_uri = uri
      end
    end

    def add_other_options(opts, options)
      opts.separator ""
      opts.separator "Other options:"

      return
      opts.on("-IPATH", "--include=PATH", "Add PATH to load path") do |path|
        $LOAD_PATH.unshift(path)
      end
    end
  end

  attr_reader :reference, :old_revision, :new_revision, :to
  attr_writer :from, :add_diff, :show_path, :send_push_mail, :use_utf7
  attr_writer :repository
  attr_accessor :from_domain, :max_size, :repository_uri
  attr_accessor :rss_path, :rss_uri, :name, :server, :port

  def initialize(to)
    @to = to
  end

  def from
    #@from || "#{@info.author}@#{@from_domain}".sub(/@\z/, '')
    @info.author_email
  end

  def repository
    @repository || Dir.pwd
  end

  def short_new_revision
    GitCommitMailer.short_revision(@new_revision)
  end

  def short_old_revision
    GitCommitMailer.short_revision(@old_revision)
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

  def detect_revision_type(change_type)
    case change_type
    when :create, :update
      `git cat-file -t #@new_revision`.strip
    when :delete
      `git cat-file -t #@old_revision`.strip
    end
  end

  def detect_reference_type(revision_type)
    if reference =~ /refs\/tags\/.*/ and revision_type == "commit"
      # un-annotated tag
      "tag"
    elsif reference =~ /refs\/tags\/.*/ and revision_type == "tag"
      # annotated tag
      # change recipients
      #if [ -n "$announcerecipients" ]; then
      #  recipients="$announcerecipients"
      #fi
      "annotated tag"
    elsif reference =~ /refs\/heads\/.*/ and revision_type == "commit"
      # branch
      "branch"
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

  def return_push_message_and_yield(reference_type, change_type, block)
    if reference_type == "branch" and change_type == :update
      process_update_branch(block)
    elsif reference_type == "branch" and change_type == :create
      process_create_branch(block)
    elsif reference_type == "branch" and change_type == :delete
      process_delete_branch(block)
    elsif reference_type == "annotated tag" and change_type == :update
      process_update_atag
    elsif reference_type == "annotated tag" and change_type == :create
      process_create_atag
    elsif reference_type == "annotated tag" and change_type == :delete
      process_delete_atag
    end
  end

  def each_revision(&block)
    change_type = detect_change_type
    revision_type = detect_revision_type(change_type)
    reference_type = detect_reference_type(revision_type)

    push_messsage = return_push_message_and_yield(reference_type, change_type,
                                                  block)

    [reference_type, change_type, push_messsage]
  end

  def excluded_revisions
     # refer to the long comment located at the top of this file for the
     # explanation of this command.
     current_reference_rev = `git rev-parse #@reference`.strip
     `git rev-parse --not --branches`.lines.find_all do |line|
       line.strip!
       not line.index(current_reference_rev)
     end.join(' ')
  end

  def process_create_branch(block)
    msg = "Branch (#@reference) is created.\n"

    commit_list = []
    `git rev-list #@new_revision #{excluded_revisions}`.lines.
    reverse_each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)
      block.call(revision)
      subject = GitCommitMailer.get_record(revision,'%s')
      commit_list << "     via  #{short_revision} #{subject}\n"
    end
    if commit_list.length > 0
      commit_list[-1].sub!(/\A     via  /,'     at   ')
      msg << commit_list.join
    end

    msg
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

  def process_update_branch(block)
    msg = "Branch (#@reference) is updated.\n"

    # List all of the revisions that were removed by this update, in a
    # fast forward update, this list will be empty, because rev-list O
    # ^N is empty.  For a non fast forward, O ^N is the list of removed
    # revisions
    fast_forward = false
    revision = nil
    short_revision = nil
    revision_list = []
    `git rev-list #@new_revision..#@old_revision`.lines.each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)
      subject = GitCommitMailer.get_record(revision, '%s')
      revision_list << "discards  #{short_revision} #{subject}\n"
    end
    unless revision
      fast_forward = true
      subject = GitCommitMailer.get_record(old_revision,'%s')
      revision_list << "    from  #{short_old_revision} #{subject}\n"
    end

    # List all the revisions from baserev to new_revision in a kind of
    # "table-of-contents"; note this list can include revisions that
    # have already had notification emails and is present to show the
    # full detail of the change from rolling back the old revision to
    # the base revision and then forward to the new revision
    tmp = []
    `git rev-list #@old_revision..#@new_revision`.lines.each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)

      subject = GitCommitMailer.get_record(revision, '%s')
      tmp << "     via  #{short_revision} #{subject}\n"
    end
    revision_list.concat(tmp.reverse)

    unless fast_forward
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
      baserev = `git merge-base #@old_revision #@new_revision`.strip
      rewind_only = false
      if baserev == new_revision
        msg << explain_rewind
        rewind_only = true
      else
        msg << explain_rewind_and_new_commits
      end
    end

    msg << "\n"
    msg << revision_list.join

    no_actual_output = true
    unless rewind_only
      `git rev-list #@old_revision..#@new_revision #{excluded_revisions}`.lines.
      reverse_each do |revision|
        block.call(revision.strip)
        no_actual_output = false
      end
    end
    if rewind_only or no_actual_output
      msg << "\n"
      msg << "No new revisions were added by this update.\n"
    end

    msg
  end

  def process_delete_branch(block)
    "Branch (#@reference) is deleted.\n" +
    "       was  #@old_revision\n\n" +
    `git show -s --pretty=oneline #@old_revision`
  end

  def process_create_atag
    "Annotated tag (#@reference) is created.\n" +
    "        at  #@new_revision (tag)\n" +
    process_atag
  end

  def process_update_atag
    "Annotated tag (#@reference) is updated.\n" +
    "        to  #@new_revision (tag)\n" +
    "      from  #@old_revision (which is now obsolete)\n" +
    process_atag
  end

  def process_delete_atag
    "Annotated tag (#@reference) is deleted.\n" +
    "       was  #@old_revision\n\n" +
    `git show -s --pretty=oneline #@old_revision`
  end

  def process_atag
    msg = ''
    # Use git for-each-ref to pull out the individual fields from the
    # tag
    tag_object = `git for-each-ref --format='%(*objectname)' #@reference`.strip
    tag_type = `git for-each-ref --format='%(*objecttype)' #@reference`.strip
    tagger = `git for-each-ref --format='%(taggername)' #@reference`.strip
    tagged = `git for-each-ref --format='%(taggerdate)' #@reference`.strip
    prev_tag = nil

    msg << "   tagging  #{tag_object} (#{tag_type})\n"
    case tag_type
    when "commit"
      # If the tagged object is a commit, then we assume this is a
      # release, and so we calculate which tag this tag is
      # replacing
      prev_tag = `git describe --abbrev=0 #@new_revision^`.strip

      msg << "  replaces  #{prev_tag}\n" if prev_tag
    else
      msg << "    length  #{`git cat-file -s #{tag_object}`.strip} bytes\n"
    end
    msg << " tagged by  #{tagger}\n"
    msg << "        on  #{tagged}\n\n"

    # Show the content of the tag message; this might contain a change
    # log or release notes so is worth displaying.
    tag_content = `git cat-file tag #@new_revision`.split("\n")
    tag_content.shift while not tag_content[0].empty?
    tag_content.shift
    msg << tag_content.join("\n")

    case tag_type
    when "commit"
      # Only commit tags make sense to have rev-list operations
      # performed on them
      if prev_tag
        # Show changes since the previous release
        msg << `git rev-list --pretty=short \"#{prev_tag}..#@new_revision\" |
                git shortlog`
      else
        # No previous tag, show all the changes since time
        # began
        msg << `git rev-list --pretty=short #@new_revision | git shortlog`
      end
    else
      # XXX: Is there anything useful we can do for non-commit
      # objects?
    end
    msg
  end

  def find_branch_name_from_its_descendant_revision(revision)
    begin
      name = `git name-rev --name-only --refs refs/heads/* #{revision}`.strip
      revision = `git rev-parse #{revision}~`.strip
    end until name.sub(/([~^][0-9]+)*\z/,'') == name
    name
  end

  def traverse_merge_commit(merge_commit)
    first_grand_parent = `git rev-parse #{merge_commit.first_parent}~`.strip

    [merge_commit.first_parent, *merge_commit.other_parents].each do |revision|
      is_traversing_first_parent = (revision == merge_commit.first_parent)
      base_revision = `git merge-base #{first_grand_parent} #{revision}`.strip
      base_revisions = [@old_revision, base_revision]
      #branch_name = find_branch_name_from_its_descendant_revision(revision)
      descendant_revision = merge_commit.revision

      until base_revisions.index(revision)
        unless commit_info = @commit_info_map[revision]
          commit_info = CommitInfo.new(repository, @reference, revision)
          i = @commit_infos.index(@commit_info_map[descendant_revision])
          @commit_infos.insert(i, commit_info)
          @commit_info_map[revision] = commit_info
        else
          commit_info.reference = @reference
        end

        merge_message = "Merged #{merge_commit.short_revision}: #{merge_commit.subject}"
        if not is_traversing_first_parent and not commit_info.merge_status.index(merge_message)
          commit_info.merge_status << merge_message
        end

        if commit_info.merge?
          traverse_merge_commit(commit_info)
          base_revision = `git merge-base #{first_grand_parent} #{commit_info.first_parent}`.strip
          base_revisions << base_revision unless base_revisions.index(base_revision)
        end
        descendant_revision, revision = revision, commit_info.first_parent
      end
    end
  end

  def post_process_infos
    #@push_info.author = determine_prominent_author
    commit_infos = @commit_infos.dup
    #@comit_infos may be altered and I don't know any sensible behavior of ruby
    #in such cases. Take the safety measure at the moment...
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

  def process_single_ref_change(old_revision, new_revision, reference)
    @old_revision = old_revision
    @new_revision = new_revision
    @reference = reference

    @push_info = nil
    @commit_infos = []
    @commit_info_map = {}

    catch (:no_email) do
      push_info_args = each_revision do |revision|
        commit_info = CommitInfo.new(repository, reference, revision)
        @commit_infos << commit_info
        @commit_info_map[revision] = commit_info
      end

      if push_info_args
        @push_info = PushInfo.new(old_revision, new_revision, reference,
                                  *push_info_args)
      else
        return
      end
    end

    post_process_infos

    @info = @push_info
    @push_mail = make_mail

    @commit_mails = []
    @commit_infos.each do |info|
      @info = info
      @commit_mails << make_mail
    end

    #output_rss #XXX eneble this in the future

    [@push_mail, @commit_mails]
  end

  def send_all_mails
    send_mail @push_mail if send_push_mail?

    @commit_mails.each do |mail|
      send_mail mail
    end
  end

  def use_utf7?
    @use_utf7
  end

  def add_diff?
    @add_diff
  end

  def show_path?
    @show_path
  end

  def send_push_mail?
    @send_push_mail
  end

  private
  def extract_email_address(address)
    if /<(.+?)>/ =~ address
      $1
    else
      address
    end
  end

  def send_mail(mail)
    _from = extract_email_address(from)
    to = @to.collect {|address| extract_email_address(address)}
    Net::SMTP.start(@server || "localhost", @port) do |smtp|
      smtp.open_message_stream(_from, to) do |f|
        f.print(mail)
      end
    end
  end

  def output_rss
    return unless rss_output_available?
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

  def make_mail
    utf8_body = make_body
    utf7_body = nil
    utf7_body = utf8_to_utf7(utf8_body) if use_utf7?
    if utf7_body
      body = utf7_body
      encoding = "utf-7"
      bit = "7bit"
    else
      body = utf8_body
      encoding = "utf-8"
      bit = "8bit"
    end

    unless @max_size.nil?
      body = truncate_body(body, !utf7_body.nil?)
    end

    make_header(encoding, bit) + "\n" + body
  end

  def make_body
    if @info.class == CommitInfo
      body = ""
      body << "#{@info.author}\t#{format_time(@info.date)}\n"
      body << "\n"
      body << "  New Revision: #{@info.revision}\n"
      body << "\n"
      unless @info.merge_status.length.zero?
        body << "  #{@info.merge_status.join("\n  ")}\n\n"
      end
      body << "  Log:\n"
      @info.log.rstrip.each_line do |line|
        body << "    #{line}"
      end
      body << "\n\n"
      body << added_files
      body << copied_files
      body << deleted_files
      body << modified_files
      body << renamed_files

      body << "\n"
      body << change_info
    elsif @info.class == PushInfo
      body = ""
      body << "#{@info.author}\t#{format_time(@info.date)}\n"
      body << "\n"
      body << "New Push:\n"
      body << "\n"
      body << "  Log:\n"
      @info.log.rstrip.each_line do |line|
        body << "    #{line}"
      end
      body << "\n\n"
    else
      raise "a new Info Class?"
    end
    body
  end

  def format_time(time)
    time.strftime('%Y-%m-%d %X %z (%a, %d %b %Y)')
  end

  def changed_items(title, type, items)
    rv = ""
    unless items.empty?
      rv << "  #{title} #{type}:\n"
      if block_given?
        yield(rv, items)
      else
        rv << items.collect {|item| "    #{item}\n"}.join('')
      end
    end
    rv
  end

  def changed_files(title, files, &block)
    changed_items(title, "files", files, &block)
  end

  def added_files
    changed_files("Added", @info.added_files)
  end

  def deleted_files
    changed_files("Removed", @info.deleted_files)
  end

  def modified_files
    changed_files("Modified", @info.updated_files)
  end

  def copied_files
    changed_files("Copied", @info.copied_files) do |rv, files|
      rv << files.collect do |from_file, to_file|
        <<-INFO
    #{to_file}
      (from #{from_file})
INFO
      end.join("")
    end
  end

  def renamed_files
    changed_files("Renamed", @info.renamed_files) do |rv, files|
      rv << files.collect do |from_file, to_file|
        <<-INFO
    #{to_file}
      (from #{from_file})
INFO
      end.join("")
    end
  end

  CHANGED_TYPE = {
    :added => "Added",
    :modified => "Modified",
    :deleted => "Deleted",
    :copied => "Copied",
    :renamed => "Renamed",
  }

  def change_info
    result = ""
    diff_info.each do |desc|
      result << "#{desc}\n"
    end
    result
  end

  def diff_info
    @info.diffs.collect do |diff|
      args = []
      short_revision = diff.short_new_revision
      similarity_index = ""
      file_mode = ""
      case diff.type
      when :added
        command = "show"
        file_mode = " #{diff.new_file_mode}"
      when :deleted
        command = "show"
        file_mode = " #{diff.deleted_file_mode}"
        short_revision = diff.short_old_revision
      when :modified
        command = "diff"
        args.concat(["-r", diff.short_old_revision, diff.short_new_revision,
                     diff.link])
      when :renamed
        command = "diff"
        args.concat(["-C","--diff-filter=R",
                     "-r", diff.short_old_revision, diff.short_new_revision, "--",
                     diff.from_file, diff.to_file])
        similarity_index = " #{diff.similarity_index}%"
      when :copied
        command = "diff"
        args.concat(["-C","--diff-filter=C",
                     "-r", diff.short_old_revision, diff.short_new_revision, "--",
                     diff.from_file, diff.to_file])
        similarity_index = " #{diff.similarity_index}%"
      else
        raise "unknown diff type: #{diff.type}"
      end
      if command == "show"
        args.concat(["#{short_revision}:#{diff.link}"])
      end

      command += " #{args.join(' ')}" unless args.empty?

      line_info = "+#{diff.added_line} -#{diff.deleted_line}"
      desc =  "  #{CHANGED_TYPE[diff.type]}: #{diff.file} (#{line_info})"
      desc << "#{file_mode}#{similarity_index}\n"
      if diff.mode_changed?
        desc << "  Mode: #{diff.old_mode} -> #{diff.new_mode}\n"
      end
      desc << "#{"=" * 67}\n"

      if add_diff?
        desc << diff.value
      else
        desc << <<-CONTENT
    % git #{command}
CONTENT
      end

      desc
    end
  end

  def make_header(body_encoding, body_encoding_bit)
    headers = []
    headers += @info.headers
    headers << "MIME-Version: 1.0"
    headers << "Content-Type: text/plain; charset=#{body_encoding}"
    headers << "Content-Transfer-Encoding: #{body_encoding_bit}"
    headers << "From: #{from}"
    headers << "To: #{to.join(', ')}"
    headers << "Subject: #{(@name+' ') if @name}#{make_subject}"
    headers << "Date: #{@info.date.rfc2822}"
    headers.find_all do |header|
      /\A\s*\z/ !~ header
    end.join("\n")
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

  def make_subject
    subject = ""
    affected_path_info = ""

    if @info.class == CommitInfo
      if show_path?
        _affected_paths = affected_paths
        unless _affected_paths.empty?
          affected_path_info = " (#{_affected_paths.join(',')})"
        end
      end

      subject << "[#{@info.short_reference}#{affected_path_info}] "
      subject << @info.subject
    elsif @info.class == PushInfo
      subject << "(push) "
      subject << "#{@info.reference_type} (#{@info.short_reference}) is" +
                 " #{PushInfo::CHANGE_TYPE[@info.change_type]}."
    else
      raise "a new Info class?"
    end

    NKF.nkf("-WM", subject)
  end

  def affected_paths
    paths = []
    sub_paths = @info.sub_paths('')
    paths.concat(sub_paths)
    paths.uniq
  end

  def utf8_to_utf7(utf8)
    require 'iconv'
    Iconv.conv("UTF-7", "UTF-8", utf8)
  rescue InvalidEncoding
    begin
      Iconv.conv("UTF7", "UTF8", utf8)
    rescue Exception
      nil
    end
  rescue Exception
    nil
  end

  def truncate_body(body, use_utf7)
    return body if body.size < @max_size

    truncated_body = body[0, @max_size]
    formatted_size = self.class.format_size(@max_size)
    truncated_message = "... truncated to #{formatted_size}\n"
    truncated_message = utf8_to_utf7(truncated_message) if use_utf7
    truncated_message_size = truncated_message.size

    lf_index = truncated_body.rindex(/(?:\r|\r\n|\n)/)
    while lf_index
      if lf_index + truncated_message_size < @max_size
        truncated_body[lf_index, @max_size] = "\n#{truncated_message}"
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
      maker.channel.title = rss_title(@name || @repository_uri)
      maker.channel.link = @repository_uri
      maker.channel.description = rss_title(@name || @repository_uri)
      maker.channel.dc_date = @info.date

      if base_rss
        base_rss.items.each do |item|
          item.setup_maker(maker)
        end
      end

      diff_info.each do |name, infos|
        infos.each do |desc, link|
          item = maker.items.new_item
          item.title = name
          item.description = @info.log
          item.content_encoded = "<pre>#{RSS::Utils.html_escape(desc)}</pre>"
          item.link = link
          item.dc_date = @info.date
          item.dc_creator = @info.author
        end
      end

      maker.items.do_sort = true
      maker.items.max_size = 15
    end
  end

  def rss_title(name)
    "Repository of #{name}"
  end
end

if __FILE__ == $0
  begin
    mailer = GitCommitMailer.parse_options_and_create(argv)

    while line = STDIN.gets
      old_revision, new_revision, reference = line.split
      mailer.process_single_ref_change(old_revision, new_revision, reference)
      mailer.send_all_mails
    end
  rescue Exception => error
    require 'net/smtp'
    require 'socket'

    to = []
    subject = "Error"
    from = "#{ENV['USER']}@#{Socket.gethostname}"
    server = nil
    port = nil
    begin
      _to, options = GitCommitMailer.parse(argv)
      to = [_to]
      to = options.error_to unless options.error_to.empty?
      from = options.from || from
      subject = "#{options.name}: #{subject}" if options.name
      server = options.server
      port = options.port
    rescue OptionParser::MissingArgument
      argv.delete_if {|arg| $!.args.include?(arg)}
      retry
    rescue OptionParser::ParseError
      if to.empty?
        _to, *_ = ARGV.reject {|arg| /^-/.match(arg)}
        to = [_to]
      end
    end

    detail = <<-EOM
  #{error.class}: #{error.message}
  #{error.backtrace.join("\n")}
  EOM
    to = to.compact
    if to.empty?
      STDERR.puts detail
    else
      sendmail(to, from, <<-MAIL, server, port)
  MIME-Version: 1.0
  Content-Type: text/plain; charset=us-ascii
  Content-Transfer-Encoding: 7bit
  From: #{from}
  To: #{to.join(', ')}
  Subject: #{subject}
  Date: #{Time.now.rfc2822}

  #{detail}
  MAIL
    end
  end
end
