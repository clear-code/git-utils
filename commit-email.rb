# See also post-receive-email in git for git repository
# change detection:
#   http://git.kernel.org/?p=git/git.git;a=blob;f=contrib/hooks/post-receive-email
    def git(command)
      @mailer.git(command)
      @mailer.get_record(@revision, record)
    def initialize(mailer, old_revision, new_revision, reference,
      @mailer = mailer
      def initialize(mailer, lines, revision)
        @mailer = mailer
        @new_date = Time.at(@mailer.get_record(@new_revision, "%at").to_i)
        begin
          @old_revision = @mailer.git("log -n 1 --pretty=format:%H #{revision}~").strip
          @old_date = Time.at(@mailer.get_record(@old_revision, "%at").to_i)
        rescue
          @old_revision = '0' * 40
          @old_date = nil
        end
        #@old_revision = git("rev-parse #{revision}~").strip
    attr_reader :revision
    def initialize(mailer, reference, revision)
      @mailer = mailer
      @log = git("log -n 1 --pretty=format:%s%n%n%b #{@revision}")
      output = git("log -n 1 --pretty=format:'' -C -p #{@revision}")
      output = output.lines.to_a
      output.shift #removes the first empty line
      line = output.shift
      while line = output.shift
          @diffs << DiffPerFile.new(@mailer, lines, @revision)
      @diffs << DiffPerFile.new(@mailer, lines, @revision) if lines.length > 0
      git("log -n 1 --pretty=format:'' -C --name-status #{@revision}").
    def execute(command)
      result = `#{command} < /dev/null 2> /dev/null`
      raise "execute failed:#{command}" unless $?.exitstatus.zero?
      result
    end

    def git(repository, command)
      execute "git --git-dir=#{repository} #{command}"
    end

    def get_record(repository, revision, record)
      git(repository, "log -n 1 --pretty=format:'#{record}' #{revision}").strip
  def create_push_info(*args)
    PushInfo.new(self, *args)
  end

  def create_commit_info(*args)
    CommitInfo.new(self, *args)
  end

  def git(command)
    GitCommitMailer.git(@repository, command)
  end

  def get_record(revision, record)
    GitCommitMailer.get_record(@repository, revision, record)
  end

      git("cat-file -t #@new_revision").strip
      git("cat-file -t #@old_revision").strip
     current_reference_rev = git("rev-parse #@reference").strip
     git("rev-parse --not --branches").lines.find_all do |line|
    git("rev-list #@new_revision #{excluded_revisions}").lines.
      subject = get_record(revision,'%s')
    git("rev-list #@new_revision..#@old_revision").lines.each do |revision|
      subject = get_record(revision, '%s')
      subject = get_record(old_revision,'%s')
    git("rev-list #@old_revision..#@new_revision").lines.each do |revision|
      subject = get_record(revision, '%s')
      baserev = git("merge-base #@old_revision #@new_revision").strip
      git("rev-list #@old_revision..#@new_revision #{excluded_revisions}").lines.
    git("show -s --pretty=oneline #@old_revision")
    git("show -s --pretty=oneline #@old_revision")
    tag_object = git("for-each-ref --format='%(*objectname)' #@reference").strip
    tag_type = git("for-each-ref --format='%(*objecttype)' #@reference").strip
    tagger = git("for-each-ref --format='%(taggername)' #@reference").strip
    tagged = git("for-each-ref --format='%(taggerdate)' #@reference").strip
      prev_tag = git("describe --abbrev=0 #@new_revision^").strip
      msg << "    length  #{git("cat-file -s #{tag_object}").strip} bytes\n"
    tag_content = git("cat-file tag #@new_revision").split("\n")
        msg << git("rev-list --pretty=short \"#{prev_tag}..#@new_revision\" |
                    git shortlog")
        msg << git("rev-list --pretty=short #@new_revision | git shortlog")
      name = git("name-rev --name-only --refs refs/heads/* #{revision}").strip
      revision = git("rev-parse #{revision}~").strip
    first_grand_parent = git("rev-parse #{merge_commit.first_parent}~").strip
      base_revision = git("merge-base #{first_grand_parent} #{revision}").strip
          commit_info = create_commit_info(@reference, revision)
          base_revision = git("merge-base #{first_grand_parent} #{commit_info.first_parent}").strip
        commit_info = create_commit_info(reference, revision)
        @push_info = create_push_info(old_revision, new_revision, reference,
                                      *push_info_args)