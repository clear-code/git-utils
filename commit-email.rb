#!/usr/bin/env ruby
#
# Copyright (C) 2009  Kouhei Sutou <kou@clear-code.com>
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

require 'English'

original_argv = ARGV.dup
argv = []

LOGBEGIN="- Log -----------------------------------------------------------------"
LOGEND  ="-----------------------------------------------------------------------"

ENV.each_pair { |k, v| puts "pair[#{k}] => #{v}" }


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


require "optparse"
require "ostruct"
require "time"
require "net/smtp"
require "socket"
require "nkf"

class GitCommitMailer
  class PushInfo
    attr_reader :old_rev, :new_rev, :reference, :reftype, :log, :author_email
    def initialize(old_rev, new_rev, reference, reftype, log)
      @old_rev = old_rev
      @new_rev = new_rev
      @reference = reference
      @reftype = reftype
      @log = log
      @author_email = "onodera@clear-code.com"
    end

    def headers
      [ "X-Git-Oldrev: #{old_rev}",
        "X-Git-Newrev: #{new_rev}",
        "X-Git-Refname: #{reference}",
        "X-Git-Reftype: #{reftype}" ]
    end

    def subject
        "[push] #{reftype}, #{reference.sub(/\A.+\/.+\//,'')}, ${change_type}d. $describe"
    end
  end

  class CommitInfo
    attr_reader :revision, :author, :date, :subject, :log, :commit_id, :author_email
    def initialize(repository, reference, revision)
      @repository = repository
      @reference = reference
      @revision = revision
      parse
    end

    def get_record(record)
      IO.popen("git log -n 1 --pretty=format:#{record} #{@revision}").readlines[0].strip
    end

    def parse
      @author = get_record("%an")
      @author_email = get_record("%ae")
      @date = Time.at(get_record("%at").to_i)
      @subject ="[commit] " + get_record("%s")
      @log = IO.popen("git log -n 1 -p --pretty=full --find-copies-harder #{revision}").readlines.join #+
      #IO.popen("git log -p -n 1 --find-copies-harder #{revision}").readlines.join
      @commit_id = get_record("%H")
    end

    def headers
      [ "X-Git-Author: #{author}",
        "X-Git-Revision: #{revision}",
        # "X-Git-Repository: #{path}",
        "X-Git-Repository: XXX",
        "X-Git-Commit-Id: #{commit_id}" ]
    end

    def make_subject
      subject = ""
      subject << "#{@name} " if @name
      revision_info = "#{@info.revision[0,7]}"
      if show_path?
        _affected_paths = affected_paths(project)
        unless _affected_paths.empty?
          revision_info = "(#{_affected_paths.join(',')}) #{revision_info}"
        end
      end
      if project
        subject << "[#{project} #{revision_info}] "
      else
        subject << "#{revision_info}: "
      end
      subject << @info.subject
      NKF.nkf("-WM", subject)
    end
  end

  class << self
    def run(argv=nil)
      argv ||= ARGV
      old_revision, new_revision, reference, to, options = parse(argv)
      to = [to, *options.to].compact
      mailer = new(old_revision, new_revision, reference, to)
      apply_options(mailer, options)
      mailer.run
    end

    def parse(argv)
      options = make_options

      parser = make_parser(options)
      argv = argv.dup
      parser.parse!(argv)
      old_revision, new_revision, reference, to, *rest = argv

      [old_revision, new_revision, reference, to, options]
    end

    DEFAULT_MAX_SIZE = '100000B'
    KILO_SIZE = 1024
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
      options.repository = "."
      #options.reference = "refs/heads/master"
      options.to = ["user@localhost"]
      options.error_to = []
      options.from = nil
      options.from_domain = nil
      options.add_diff = true
      options.max_size = parse_size(DEFAULT_MAX_SIZE)
      options.repository_uri = nil
      options.rss_path = nil
      options.rss_uri = nil
      options.show_path = false
      options.name = nil
      options.use_utf7 = false
      options.server = "localhost"
      options.port = Net::SMTP.default_port
      options
    end

    def make_parser(options)
      OptionParser.new do |opts|
        opts.banner += " OLD_REVISION NEW_REVISION TO"

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

  attr_reader :to
  attr_writer :from, :add_diff, :show_path, :use_utf7
  attr_writer :repository
  attr_accessor :from_domain, :max_size, :repository_uri
  attr_accessor :rss_path, :rss_uri, :name, :server, :port

  def initialize(old_revision, new_revision, reference, to)
    @old_revision = old_revision
    @new_revision = new_revision
    @reference = reference
    @to = to
  end

  def from
    #@from || "#{@info.author}@#{@from_domain}".sub(/@\z/, '')
    @info.author_email
  end

  def repository
    @repository || Dir.pwd
  end

  def reference
    @reference || "refs/heads/master"
  end

  def each_revision(old_revision, new_revision, &block)
    if not old_revision =~ /0{40}/ and not new_revision =~ /0{40}/
      change_type = "update"
    elsif old_revision =~ /0{40}/
      change_type = "create"
    elsif new_revision =~ /0{40}/
      change_type = "delete"
    else
      return #error - should throw something?
    end

    case change_type
    when "create", "update"
      rev = new_revision
      rev_type=`git cat-file -t #{new_revision}`.strip
    when "delete"
      rev = old_revision
      rev_type=`git cat-file -t #{old_revision}`.strip
    end

    if reference =~ /refs\/tags\/.*/ and rev_type == "commit"
      # un-annotated tag
      refname_type="tag"
      short_refname=reference.sub(/\Arefs\/tags\//,'')
    elsif reference =~ /refs\/tags\/.*/ and rev_type == "tag"
      # annotated tag
      refname_type="annotated tag"
      short_refname=reference.sub(/\Arefs\/tags\//,'')
      # change recipients
      #if [ -n "$announcerecipients" ]; then
      #  recipients="$announcerecipients"
      #fi
    elsif reference =~ /refs\/heads\/.*/ and rev_type == "commit"
      # branch
      refname_type="branch"
      short_refname=reference.sub(/\Arefs\/heads\//,'')
    elsif reference =~ /refs\/remotes\/.*/ and rev_type == "commit"
      # tracking branch
      refname_type="tracking branch"
      short_refname=reference.sub(/\Arefs\/remotes\//,'')
      $stderr << "*** Push-update of tracking branch, $refname"
      $stderr << "***  - no email generated."
      return
    else
      # Anything else (is there anything else?)
      $stderr << "*** Unknown type of update to $refname ($rev_type)"
      $stderr << "***  - no email generated"
      return #error - should throw
    end

      msg = <<EOF
This is an automated email from the git hooks/post-receive script. It was
generated because a ref change was pushed to the repository containing
the project "#{`sed -ne '1p' "$GIT_DIR/description"`.strip}".

The #{refname_type}, #{reference.sub(/\A.+\/.+\//,'')} has been #{change_type}d
EOF

    if refname_type == "branch" and change_type == "update"
      msg += process_update_branch(old_revision, new_revision, block)
    elsif refname_type == "branch" and change_type == "create"
      msg += process_create_branch(old_revision, new_revision, block)
    elsif refname_type == "branch" and change_type == "delete"
      msg += process_delete_branch(old_revision, new_revision, block)
    elsif refname_type == "annotated tag" and change_type == "update"
      msg += process_update_atag(old_revision, new_revision)
    elsif refname_type == "annotated tag" and change_type == "create"
      msg += process_create_atag(old_revision, new_revision)
    elsif refname_type == "annotated tag" and change_type == "delete"
      msg += process_delete_atag(old_revision, new_revision)
    end

    @info = PushInfo.new(old_revision, new_revision, reference, refname_type, msg)
    send_mail make_mail
  end

  def process_create_branch(old_revision, new_revision, block)
    # This shows all log entries that are not already covered by
    # another ref - i.e. commits that are now accessible from this
    # ref that were previously not accessible
    # (see generate_update_branch_email for the explanation of this
    # command)
    msg = ""
    msg << "        at  #{new_revision} (branch)\n"
    msg << "\n"

    `git rev-parse --not --branches | grep -v $(git rev-parse #{reference}) |
    git rev-list --stdin #{new_revision}`.lines.each { |rev|
      block.call(rev.strip)
    }
    msg
  end

  def process_update_branch(old_revision, new_revision, block)
    # Consider this:
    #   1 --- 2 --- O --- X --- 3 --- 4 --- N
    #
    # O is $oldrev for $refname
    # N is $newrev for $refname
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
    # our $newrev would be an ancestor of that commit, it would exclude
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
    #   * --- B --- * --- O ($oldrev)
    #          \
    #           * --- X --- * --- N ($newrev)
    #
    # That is to say, there is no guarantee that oldrev is a strict
    # subset of newrev (it would have required a --force, but that's
    # allowed).  So, we can't simply say rev-list $oldrev..$newrev.
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

    # List all of the revisions that were removed by this update, in a
    # fast forward update, this list will be empty, because rev-list O
    # ^N is empty.  For a non fast forward, O ^N is the list of removed
    # revisions
    fast_forward = false
    rev = nil
    msg = ""
    newrev = new_revision
    oldrev = old_revision
    `git rev-list #{newrev}..#{oldrev}`.lines.each { |rev|
      rev.strip!
      revtype=`git cat-file -t #{rev}`.strip
      msg << "  discards  #{rev} (#{revtype})\n"
    }
    if not rev
      fast_forward = true
    end

    # List all the revisions from baserev to newrev in a kind of
    # "table-of-contents"; note this list can include revisions that
    # have already had notification emails and is present to show the
    # full detail of the change from rolling back the old revision to
    # the base revision and then forward to the new revision
    `(git rev-list #{oldrev}..#{newrev})`.lines.each { |rev|
      rev.strip!
      revtype=`git cat-file -t #{rev}`.strip
      msg << "       via  #{rev} (#{revtype})\n"
    }
    if fast_forward
      msg << "      from  #{oldrev} (commit)\n"
    else
      #  1. Existing revisions were removed.  In this case newrev
      #     is a subset of oldrev - this is the reverse of a
      #     fast-forward, a rewind
      #  2. New revisions were added on top of an old revision,
      #     this is a rewind and addition.

      # (1) certainly happened, (2) possibly.  When (2) hasn't
      # happened, we set a flag to indicate that no log printout
      # is required.

      # Find the common ancestor of the old and new revisions and
      # compare it with newrev
      baserev = `git merge-base #{oldrev} #{newrev}`.strip
      rewind_only = false
      if baserev == newrev
        msg << "This update discarded existing revisions and left the branch pointing at\n"
        msg << "a previous point in the repository history.\n"
        msg << "\n"
        msg << " * -- * -- N (#{newrev})\n"
        msg << "            \\\n"
        msg << "             O -- O -- O (#{oldrev})\n"
        msg << "\n"
        msg << "The removed revisions are not necessarilly gone - if another reference\n"
        msg << "still refers to them they will stay in the repository.\n"
        rewind_only = true
      else
        msg << "This update added new revisions after undoing existing revisions.  That is\n"
        msg << "to say, the old revision is not a strict subset of the new revision.  This\n"
        msg << "situation occurs when you --force push a change and generate a repository\n"
        msg << "containing something like this:\n"
        msg << "\n"
        msg << " * -- * -- B -- O -- O -- O (#{oldrev})\n"
        msg << "            \\\n"
        msg << "             N -- N -- N (#{newrev})\n"
        msg << "\n"
        msg << "When this happens we assume that you've already had alert emails for all\n"
        msg << "of the O revisions, and so we here report only the revisions in the N\n"
        msg << "branch from the common base, B.\n"
      end
    end

    msg << "\n\n"

    if not rewind_only
      msg << "Those revisions listed above that are new to this repository have\n"
      msg << "not appeared on any other notification email; so we list those\n"
      msg << "revisions in full, below.\n\n"

      #echo $LOGBEGIN
      msg << `git rev-parse --not --branches | grep -v $(git rev-parse #{reference}) | git rev-list --pretty=oneline --stdin #{oldrev}..#{newrev}`

      # XXX: Need a way of detecting whether git rev-list actually
      # outputted anything, so that we can issue a "no new
      # revisions added by this update" message

      #echo $LOGEND
    else
      msg << "No new revisions were added by this update.\n"
    end

    # The diffstat is shown from the old revision to the new revision.
    # This is to show the truth of what happened in this change.
    # There's no point showing the stat from the base to the new
    # revision because the base is effectively a random revision at this
    # point - the user will be interested in what this revision changed
    # - including the undoing of previous revisions in the case of
    # non-fast forward updates.

    IO.popen("git rev-list #{old_revision}..#{new_revision}").readlines.reverse.each { |rev|
      block.call(rev.strip)
    }
    msg
  end

  def process_delete_branch(old_revision, new_revision, block)
    msg = ""
    msg << "       was  #{old_revision}\n"
    msg << "\n"
    #msg << $LOGEND
    msg << `git show -s --pretty=oneline #{old_revision}`
    #msg << $LOGEND

    msg
  end

  def process_delete_atag(old_revision, new_revision)
    msg = ""
    msg << "       was  #{old_revision}\n"
    msg << "\n"
    #echo $LOGEND
    msg << `git show -s --pretty=oneline #{old_revision}`
    #echo $LOGEND
    msg
  end

  def process_create_atag(old_revision, new_revision)
    "        at  $newrev ($newrev_type)"
  end

  def process_update_atag(old_revision, new_revision)
    "        to  $newrev ($newrev_type)"
    "      from  $oldrev (which is now obsolete)"
  end

  def run
    each_revision(@old_revision, @new_revision) do |revision|
      @info = CommitInfo.new(repository, reference, revision)
      send_mail make_mail
    end
    output_rss
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
    #f = File.open('/tmp/mail','w')
    #f << mail
    #`cat /tmp/mail | sendmail`
    #puts mail
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
    body = "\n\n"
    #body << "#{@info.author}\t#{format_time(@info.date)}\n"
    #body << "\n"
    #body << "New Revision: #{@info.revision}\n"
    #body << "\n"
    body << @info.log
    body << "\n"
    #body << added_dirs
    #body << added_files
    #body << copied_dirs
    #body << copied_files
    #body << deleted_dirs
    #body << deleted_files
    #body << modified_dirs
    #body << modified_files
    body << "\n"
    #body << change_info
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
      rv << files.collect do |file, from_file, from_rev|
        <<-INFO
    #{file}
      (from rev #{from_rev}, #{from_file})
INFO
      end.join("")
    end
  end

  def changed_dirs(title, files, &block)
    changed_items(title, "directories", files, &block)
  end

  def added_dirs
    changed_dirs("Added", @info.added_dirs)
  end

  def deleted_dirs
    changed_dirs("Removed", @info.deleted_dirs)
  end

  def modified_dirs
    changed_dirs("Modified", @info.updated_dirs)
  end

  def copied_dirs
    changed_dirs("Copied", @info.copied_dirs) do |rv, dirs|
      rv << dirs.collect do |dir, from_dir, from_rev|
        "    #{dir} (from rev #{from_rev}, #{from_dir})\n"
      end.join("")
    end
  end


  CHANGED_TYPE = {
    :added => "Added",
    :modified => "Modified",
    :deleted => "Deleted",
    :copied => "Copied",
    :property_changed => "Property changed",
  }

  CHANGED_MARK = Hash.new("=")
  CHANGED_MARK[:property_changed] = "_"

  def change_info
    result = changed_dirs_info
    result = "\n#{result}" unless result.empty?
    result << "\n"
    diff_info.each do |key, infos|
      infos.each do |desc, link|
        result << "#{desc}\n"
      end
    end
    result
  end

  def changed_dirs_info
    rev = @info.revision
    (@info.added_dirs.collect do |dir|
       "  Added: #{dir}\n"
     end + @info.copied_dirs.collect do |dir, from_dir, from_rev|
       <<-INFO
  Copied: #{dir}
    (from rev #{from_rev}, #{from_dir})
INFO
     end + @info.deleted_dirs.collect do |dir|
       <<-INFO
  Deleted: #{dir}
    % git ls #{[@repository_uri, dir].compact.join("/")}@#{rev - 1}
INFO
     end + @info.updated_dirs.collect do |dir|
       "  Modified: #{dir}\n"
     end).join("\n")
  end

  def diff_info
    @info.diffs.collect do |key, values|
      [
       key,
       values.collect do |type, value|
         args = []
         rev = @info.revision
         case type
         when :added
           command = "cat"
         when :modified, :property_changed
           command = "diff"
           args.concat(["-r", "#{@info.revision - 1}:#{@info.revision}"])
         when :deleted
           command = "cat"
           rev -= 1
         when :copied
           command = "cat"
         else
           raise "unknown diff type: #{value.type}"
         end

         command += " #{args.join(' ')}" unless args.empty?

         link = [@repository_uri, key].compact.join("/")

         line_info = "+#{value.added_line} -#{value.deleted_line}"
         desc = <<-HEADER
  #{CHANGED_TYPE[value.type]}: #{key} (#{line_info})
#{CHANGED_MARK[value.type] * 67}
HEADER

         if add_diff?
           desc << value.body
         else
           desc << <<-CONTENT
    % git #{command} #{link}@#{rev}
CONTENT
         end

         [desc, link]
       end
      ]
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
    headers << "Subject: [#{detect_project}]#{@info.subject}"
    headers << "Date: #{Time.now.rfc2822}"
    headers.find_all do |header|
      /\A\s*\z/ !~ header
    end.join("\n")
  end

  def detect_project
    project=IO.popen("sed -ne \'1p\' \"#{ENV['GIT_DIR']}/description\"").readlines[0].strip
    # Check if the description is unchanged from it's default, and shorten it to
    # a more manageable length if it is
    if project =~ /Unnamed repository.*$/
  project="UNNAMED PROJECT"
    end
    project
  end

  def affected_paths(project)
    paths = []
    [nil, :branches_path, :tags_path].each do |target|
      prefix = [project]
      prefix << send(target) if target
      prefix = prefix.compact.join("/")
      sub_paths = @info.sub_paths(prefix)
      if target.nil?
        sub_paths = sub_paths.find_all do |sub_path|
          sub_path == trunk_path
        end
      end
      paths.concat(sub_paths)
    end
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


begin
  while line = gets
    puts line
    GitCommitMailer.run(line.split + argv)
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
    _, _, _, _to, options = GitCommitMailer.parse(argv)
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
      _, _, _to, *_ = ARGV.reject {|arg| /^-/.match(arg)}
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
