#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
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

class GitCommitMailer
  KILO_SIZE = 1000
  DEFAULT_MAX_SIZE = "100M"

  class Info
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
       @reference.sub(/\A.*\/.*\//,'');
    end
  end

  class PushInfo < Info
    attr_reader :old_revision, :new_revision, :reference, :reference_type, :log
    attr_reader :author, :author_email, :date, :subject, :change_type, :commits
    def initialize(mailer, old_revision, new_revision, reference,
                   reference_type, change_type, log, commits=[])
      @mailer = mailer
      @old_revision = old_revision
      @new_revision = new_revision
      @reference = reference
      @reference_type = reference_type
      @log = log
      author, author_email = get_records(["%an", "%an <%ae>"])
      @author = author
      @author_email = author_email
      @date = @mailer.date
      @change_type = change_type
      @commits = commits || []
    end

    def revision
      @new_revision
    end

    def headers
      [ "X-Git-OldRev: #{old_revision}",
        "X-Git-NewRev: #{new_revision}",
        "X-Git-Refname: #{reference}",
        "X-Git-Reftype: #{REFERENCE_TYPE[reference_type]}" ]
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

    def mail_subject
      "(push) #{PushInfo::REFERENCE_TYPE[reference_type]} "+
      "(#{short_reference}) is #{PushInfo::CHANGE_TYPE[change_type]}."
    end

    def mail_body
      body = ""
      body << "#{author}\t#{@mailer.format_time(date)}\n"
      body << "\n"
      body << "New Push:\n"
      body << "\n"
      body << "  Log:\n"
      log.rstrip.each_line do |line|
        body << "    #{line}"
      end
      body << "\n\n"
    end
  end

  class CommitInfo < Info
    def self.unescape_file_path(file_path)
      if file_path =~ /\A"(.*)"\z/
        escaped_file_path = $1
        if escaped_file_path.respond_to?(:encoding)
          encoding = escaped_file_path.encoding
        else
          encoding = nil
        end
        unescaped_file_path = escaped_file_path.gsub(/\\\\/,'\\').
                                                gsub(/\\\"/,'"').
                                                gsub(/\\([0-9]{1,3})/) do
          $1.to_i(8).chr
        end
        unescaped_file_path.force_encoding(encoding) if encoding
        unescaped_file_path
      else
        file_path
      end
    end

    class DiffPerFile
      def initialize(mailer, lines, revision)
        @mailer = mailer
        @metadata = []
        @body = ''

        parse_header(lines, revision)
        parse_extended_headers(lines)
        parse_body(lines)
      end

      def file_path
        @to_file
      end

      def format_diff
        desc =  "  #{CHANGED_TYPE[@type]}: #{@to_file} " +
                "(+#{@added_line} -#{@deleted_line})" +
                "#{format_file_mode}#{format_similarity_index}\n"
        desc << "  Mode: #{@old_mode} -> #{@new_mode}\n" if @is_mode_changed
        desc << diff_separator

        if @mailer.add_diff?
          desc << headers + @body
        else
          desc << git_command
        end
        desc
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
        #@old_revision = @mailer.parent_commit(revision)
      end

      def parse_extended_headers(lines)
        @type = :modified
        @is_binary = false
        @is_mode_changed = false

        line = lines.shift
        while line != nil and not line =~ /\A@@/
          case line
          when /\A--- (a\/.*|"a\/.*"|\/dev\/null)\z/
            @minus_file = CommitInfo.unescape_file_path($1)
            @type = :added if $1 == '/dev/null'
          when /\A\+\+\+ (b\/.*|"b\/.*"|\/dev\/null)\z/
            @plus_file = CommitInfo.unescape_file_path($1)
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
           if @similarity_index == 100 && (@type == :renamed || @type == :copied)
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
          args = ["-C","--diff-filter=R",
                  short_old_revision, short_new_revision, "--",
                  @from_file, @to_file]
        when :copied
          command = "diff"
          args = ["-C","--diff-filter=C",
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

    attr_reader :revision
    attr_reader :author, :date, :subject, :log, :commit_id
    attr_reader :author_email, :diffs, :added_files, :copied_files
    attr_reader :deleted_files, :updated_files, :renamed_files
    attr_accessor :reference, :merge_status
    def initialize(mailer, reference, revision)
      @mailer = mailer
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
      author, author_email, date, subject, commit_id, parent_revisions =
        get_records(["%an", "%an <%ae>", "%at", "%s", "%H", "%P"])
      @author = author
      @author_email = author_email
      @date = Time.at(date.to_i)
      @subject = subject
      @commit_id = commit_id
      @parent_revisions = parent_revisions.split
      @log = git("log -n 1 --pretty=format:%s%n%n%b #{@revision}")
    end

    def parse_diff
      output = git("log -n 1 --pretty=format:'' -C -p #{@revision}")
      output = output.lines.to_a
      output.shift #removes the first empty line

      @diffs = []
      lines = []

      line = output.shift
      lines << line.chomp if line #take out the very first 'diff --git' header
      while line = output.shift
        line.chomp!
        if line =~ /\Adiff --git/
          @diffs << DiffPerFile.new(@mailer, lines, @revision)
          lines = [line]
        else
          lines << line
        end
      end

      #create the last diff terminated by the EOF
      @diffs << DiffPerFile.new(@mailer, lines, @revision) if lines.length > 0
    end

    def parse_file_status
      git("log -n 1 --pretty=format:'' -C --name-status #{@revision}").
      lines.each do |line|
        line.rstrip!
        if line =~ /\A([^\t]*?)\t([^\t]*?)\z/
          status = $1
          file = CommitInfo.unescape_file_path($2)

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

    def affected_paths
      paths = []
      sub_paths = sub_paths('')
      paths.concat(sub_paths)
      paths.uniq
    end

    def mail_subject
      affected_path_info = ""
      if @mailer.show_path?
        _affected_paths = affected_paths
        unless _affected_paths.empty?
          affected_path_info = " (#{_affected_paths.join(',')})"
        end
      end

      "[#{short_reference}#{affected_path_info}] " + subject
    end
    alias :rss_title :mail_subject

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

    def format_added_files
      changed_files("Added", added_files)
    end

    def format_deleted_files
      changed_files("Removed", deleted_files)
    end

    def format_modified_files
      changed_files("Modified", updated_files)
    end

    def format_copied_files
      changed_files("Copied", copied_files) do |rv, files|
        rv << files.collect do |from_file, to_file|
          <<-INFO
    #{to_file}
      (from #{from_file})
INFO
        end.join("")
      end
    end

    def format_renamed_files
      changed_files("Renamed", renamed_files) do |rv, files|
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

    def format_diffs
      diffs.collect do |diff|
        diff.format_diff
      end
    end

    def mail_body
      body = ""
      body << "#{author}\t#{@mailer.format_time(date)}\n"
      body << "\n"
      body << "  New Revision: #{revision}\n"
      body << "\n"
      unless merge_status.length.zero?
        body << "  #{merge_status.join("\n  ")}\n\n"
      end
      body << "  Log:\n"
      log.rstrip.each_line do |line|
        body << "    #{line}"
      end
      body << "\n\n"
      body << format_added_files
      body << format_copied_files
      body << format_deleted_files
      body << format_modified_files
      body << format_renamed_files

      body << "\n"
      formatted_diff = format_diffs.join("\n")
      body << formatted_diff
      body << "\n" unless formatted_diff.empty?
      body
    end
    alias :rss_content :mail_body
  end

  class << self
    def execute(command, working_directory=nil, &block)
      if working_directory
        cd_command = "cd #{working_directory} && "
      else
        cd_command = ""
      end
      if ENV['DEBUG']
        suppress_stderr = ''
      else
        suppress_stderr = ' 2> /dev/null'
      end

      script = "(#{cd_command}#{command})#{suppress_stderr}"
      puts script if ENV['DEBUG']
      if block_given?
        IO.popen(script, "w+", &block)
      else
        result = `#{script}`
      end
      raise "execute failed: #{command}" unless $?.exitstatus.zero?
      result
    end

    def git(repository, command, &block)
      execute("git --git-dir=#{Shellwords.escape(repository)} #{command}", &block)
    end

    def get_record(repository, revision, record)
      git(repository, "log -n 1 --pretty=format:'#{record}' #{revision}").strip
    end

    def get_records(repository, revision, records)
      git(repository,
          "log -n 1 --pretty=format:'#{records.join('%n')}%n' #{revision}").
            lines.collect do |line|
        line.strip
      end
    end

    def short_revision(revision)
      revision[0,7]
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

    def send_mail(server, port, from, to, mail)
      Net::SMTP.start(server, port) do |smtp|
        smtp.open_message_stream(from, to) do |f|
          f.print(mail)
        end
      end
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
      mailer.date = options.date
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
      options.date = nil
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

      opts.on("--date=DATE",
              "Use DATE as date of push mails (Time.parse is used)") do |date|
        options.date = Time.parse(date)
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
  attr_writer :repository, :date
  attr_accessor :from_domain, :max_size, :repository_uri
  attr_accessor :rss_path, :rss_uri, :name, :server, :port

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
    GitCommitMailer.git(@repository, command, &block)
  end

  def get_record(revision, record)
    GitCommitMailer.get_record(@repository, revision, record)
  end

  def get_records(revision, records)
    GitCommitMailer.get_records(@repository, revision, records)
  end

  def from(info)
    #@from || "#{info.author}@#{@from_domain}".sub(/@\z/, '')
    info.author_email
  end

  def repository
    @repository || Dir.pwd
  end

  def date
    @date || Time.now
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
    elsif reference =~ /refs\/heads\/.*/ and revision_type == "commit"
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
    raise "unexpected change_type" if not [:update, :create, :delete].
                                            index(change_type)

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
     git("rev-parse --not --branches").lines.find_all do |line|
       line.strip!
       not line.index(current_reference_revision)
     end.collect do |line|
       Shellwords.escape(line)
     end.join(' ')
  end

  def process_create_branch
    message = "Branch (#@reference) is created.\n"
    commits = []

    commit_list = []
    git("rev-list #@new_revision #{excluded_revisions}").lines.
    reverse_each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)
      commits << revision
      subject = get_record(revision,'%s')
      commit_list << "     via  #{short_revision} #{subject}\n"
    end
    if commit_list.length > 0
      commit_list[-1].sub!(/\A     via  /,'     at   ')
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
    revision = nil
    commits_summary = []
    git("rev-list #@new_revision..#@old_revision").lines.each do |revision|
      revision.strip!
      short_revision = GitCommitMailer.short_revision(revision)
      subject = get_record(revision, '%s')
      commits_summary << "discards  #{short_revision} #{subject}\n"
    end
    unless revision
      fast_forward = true
      subject = get_record(old_revision,'%s')
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
    git("rev-list #@old_revision..#@new_revision").lines.each do |revision|
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
    baserev = git("merge-base #@old_revision #@new_revision").strip
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
    git("rev-list #@old_revision..#@new_revision #{excluded_revisions}").lines.
    reverse_each do |revision|
      commits << revision.strip
    end
    commits
  end

  def process_update_branch
    message = "Branch (#@reference) is updated.\n"

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
    "Branch (#@reference) is deleted.\n" +
    "       was  #@old_revision\n\n" +
    git("show -s --pretty=oneline #@old_revision")
  end

  def process_create_annotated_tag
    "Annotated tag (#@reference) is created.\n" +
    "        at  #@new_revision (tag)\n" +
    process_annotated_tag
  end

  def process_update_annotated_tag
    "Annotated tag (#@reference) is updated.\n" +
    "        to  #@new_revision (tag)\n" +
    "      from  #@old_revision (which is now obsolete)\n" +
    process_annotated_tag
  end

  def process_delete_annotated_tag
    "Annotated tag (#@reference) is deleted.\n" +
    "       was  #@old_revision\n\n" +
    git("show -s --pretty=oneline #@old_revision")
  end

  def short_log(revision_specifier)
    log = git("rev-list --pretty=short #{Shellwords.escape(revision_specifier)}")
    git("shortlog") do |git|
      git.write(log)
      git.close_write
      return git.read
    end
  end

  def short_log_from_previous_tag(previous_tag)
    if previous_tag
      # Show changes since the previous release
      short_log("#{previous_tag}..#@new_revision")
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
      previous_tag = git("describe --abbrev=0 #{parent_commit(revision)}").strip
    rescue NoParentCommit
    end
  end

  def annotated_tag_content
    message = ''
    tagger = git("for-each-ref --format='%(taggername)' #@reference").strip
    tagged = git("for-each-ref --format='%(taggerdate:rfc2822)' #@reference").strip
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
    tag_object = git("for-each-ref --format='%(*objectname)' #@reference").strip
    tag_type = git("for-each-ref --format='%(*objecttype)' #@reference").strip

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
    raise 'unexpected' if detect_object_type(@new_revision) != "commit"

    "Unannotated tag (#@reference) is created.\n" +
    "        at  #@new_revision (commit)\n\n" +
    process_unannotated_tag(@new_revision)
  end

  def process_update_unannotated_tag
    raise 'unexpected' if detect_object_type(@new_revision) != "commit" or
                          detect_object_type(@old_revision) != "commit"

    "Unannotated tag (#@reference) is updated.\n" +
    "        to  #@new_revision (commit)\n" +
    "      from  #@old_revision (commit)\n\n" +
    process_unannotated_tag(@new_revision)
  end

  def process_delete_unannotated_tag
    raise 'unexpected' unless detect_object_type(@old_revision) == "commit"

    "Unannotated tag (#@reference) is deleted.\n" +
    "       was  #@old_revision (commit)\n\n" +
    process_unannotated_tag(@old_revision)
  end

  def process_unannotated_tag(revision)
    git("show --no-color --root -s --pretty=short #{revision}")
  end

  def find_branch_name_from_its_descendant_revision(revision)
    begin
      name = git("name-rev --name-only --refs refs/heads/* #{revision}").strip
      revision = parent_commit(revision)
    end until name.sub(/([~^][0-9]+)*\z/,'') == name
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
        unless commit_info = @commit_info_map[revision]
          commit_info = create_commit_info(@reference, revision)
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
          base_revision = git("merge-base #{first_grand_parent} #{commit_info.first_parent}").strip
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

  def reset(old_revision, new_revision, reference)
    @old_revision = old_revision
    @new_revision = new_revision
    @reference = reference

    @push_info = nil
    @commit_infos = []
    @commit_info_map = {}
  end

  def make_infos
    catch (:no_email) do
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
    @push_mail = make_mail(@push_info)

    @commit_mails = []
    @commit_infos.each do |info|
      @commit_mails << make_mail(info)
    end
  end

  def process_reference_change(old_revision, new_revision, reference)
    reset(old_revision, new_revision, reference)

    make_infos
    make_mails
    if rss_output_available?
      output_rss
    end

    [@push_mail, @commit_mails]
  end

  def send_all_mails
    if send_push_mail?
      GitCommitMailer.send_mail(*(server_and_addresses(@push_mail) + [@push_mail]))
    end

    @commit_mails.each do |mail|
      GitCommitMailer.send_mail(*(server_and_addresses(mail) + [mail]))
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

  def format_time(time)
    time.strftime('%Y-%m-%d %X %z (%a, %d %b %Y)')
  end

  private
  def server_and_addresses(mail)
    _from = GitCommitMailer.extract_email_address_from_mail(mail)
    to = @to.collect {|address| GitCommitMailer.extract_email_address(address)}
    [@server || "localhost", @port, _from, to]
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

  def make_mail(info)
    utf8_body = info.mail_body
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

    #obviously utf-8 is superset of utf-7
    if !utf7_body.nil? and body.respond_to?(:encoding)
      body.force_encoding("utf-8")
    end
    make_header(encoding, bit, info) + "\n" + body
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

  def make_header(body_encoding, body_encoding_bit, info)
    subject = "#{(name + ' ') if name}" +
              mime_encoded_word("#{info.mail_subject}")
    headers = []
    headers += info.headers
    headers << "MIME-Version: 1.0"
    headers << "Content-Type: text/plain; charset=#{body_encoding}"
    headers << "Content-Transfer-Encoding: #{body_encoding_bit}"
    headers << "From: #{from(info)}"
    headers << "To: #{to.join(', ')}"
    headers << "Subject: #{subject}"
    headers << "Date: #{info.date.rfc2822}"
    headers.find_all do |header|
      /\A\s*\z/ !~ header
    end.join("\n") + "\n"
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
    encoded_string = NKF.nkf("-wWM", string)

    #XXX work around NKF's bug of gratuitously wrapping long ascii words with
    #    MIME encoded-word syntax's header and footer, while not actually
    #    encoding the payload as base64: just strip the header and footer out.
    encoded_string.gsub!(/=\?EUC-JP\?B\?(.*)\?=\n /) {$1}
    encoded_string.gsub!(/(\n )*=\?US-ASCII\?Q\?(.*)\?=(\n )*/) {$2}

    encoded_string
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
        info.format_diffs.each do |description|
          item = maker.items.new_item
          item.title = info.rss_title
          item.description = info.log
          item.content_encoded = "<pre>#{RSS::Utils.html_escape(info.rss_content)}</pre>"
          item.link = "#{@repository_uri}/commit/?id=#{info.revision}"
          item.dc_date = info.date
          item.dc_creator = info.author
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
      mailer.process_reference_change(old_revision, new_revision, reference)
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
      from = GitCommitMailer.extract_email_address(from)
      to = to.collect {|address| GitCommitMailer.extract_email_address(address)}
      GitCommitMailer.send_mail(server || "localhost", port, from, to, <<-MAIL)
MIME-Version: 1.0
Content-Type: text/plain; charset=us-ascii
Content-Transfer-Encoding: 7bit
From: #{from}
To: #{to.join(', ')}
Subject: #{subject}
Date: #{Time.now.rfc2822}

#{detail}
  MAIL
      exit 1
    end
  end
end
