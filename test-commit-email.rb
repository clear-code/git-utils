#!/usr/bin/env ruby

require 'test/unit'
require 'tempfile'

require 'commit-email'

class GitCommitMailerTest < Test::Unit::TestCase
  def execute(command, is_debug_mode = false)
    unless is_debug_mode || @is_debug_mode
      result = `(cd #{@git_dir} && #{command}) < /dev/null 2> /dev/null`
      raise "execute failed." unless $?.exitstatus.zero?
    else
      puts "$ cd #{@git_dir} && #{command}"
      result = `(cd #{@git_dir} && #{command})`
      raise "execute failed." unless $?.exitstatus.zero?
    end
    result
  end

  def git(command, is_debug_mode = false)
    sleep 1.1 if command =~ /\A(commit|merge) / #wait for the timestamp to tick
    empty_post_receive_output if command =~ /\Apush /

    execute "git #{command}", is_debug_mode
  end

  def make_tmpname
    prefix = 'git-'
    t = Time.now.strftime("%Y%m%d")
    path = "#{prefix}#{t}-#{$$}-#{rand(0x100000000).to_s(36)}"
  end

  def config_user_info
    git 'config user.name "User Name"'
    git 'config user.email "user@example.com"'
  end

  def create_repository
    while File.exist?(@test_dir = Dir.tmpdir + "/" + make_tmpname + "/")
    end
    FileUtils.mkdir @test_dir
    @git_dir = @test_dir + 'origin/'
    @repository_dir = @git_dir + '.git/'
    FileUtils.mkdir @git_dir
    git 'init'
    config_user_info
    @post_receive_stdout = @repository_dir + 'post-receive.stdout'
    execute "chmod +x .git/hooks/post-receive"
    execute "echo \"cat >> #{@post_receive_stdout}\" >> .git/hooks/post-receive"

    place_holder_file = 'PLACE_HOLDER'
    File.open(@git_dir + place_holder_file, 'w') do |file|
      file.puts <<EOF
This is a place holder file to make the initial commit.
EOF
    end
    git 'add .'
    git 'commit -m "the initial commit"'

    git 'clone . ../repo'

    @origin_git_dir = @git_dir
    @origin_repository_dir = @repository_dir
    @git_dir = @test_dir + 'repo/'
    @repository_dir = @git_dir + '.git/'
    config_user_info
  end

  def each_post_receive_output
    ENV['GIT_DIR'] = @origin_repository_dir
    File.open(@post_receive_stdout, 'r') do |file|
      while line = file.gets
        old_revision, new_revision, reference = line.split
        yield old_revision, new_revision, reference
      end
    end
    ENV['GIT_DIR'] = nil
  end

  def process_single_ref_change(*args)
    @push_mail, @commit_mails = @mailer.process_single_ref_change(*args)
  end

  def empty_post_receive_output
    FileUtils.rm(@post_receive_stdout) if File.exist?(@post_receive_stdout)
  end

  def delete_repository
    FileUtils.rm_r @test_dir
  end

  def setup
    ENV['GIT_DIR'] = nil #XXX without this, git init would segfault.... why??
    @is_debug_mode = false

    create_repository
  end

  def teardown
    #delete_repository
  end

  def zero_revision
    '0' * 40
  end

  def create_mailer(argv)
    @mailer = GitCommitMailer.parse_options_and_create(argv.split)
    ENV['GIT_DIR'] = nil
  end

  def create_default_mailer
    create_mailer("--repository=#{@origin_repository_dir} " +
                  "--name=sample-repo " +
                  "--from from@example.com " +
                  "--error-to error@example.com to@example")
  end

  def black_out_sha1(string)
    string.gsub(/[0-9a-fA-F]{40}/, "*" * 40).
           gsub(/[0-9a-fA-F]{7}/, "*" * 7)
  end

  def black_out_date(string)
    date_format1 = '20[0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9] ' +
                   '[+-][0-9]{4} \([A-Z][a-z][a-z], [0-3][0-9] [A-Z][a-z][a-z] 20..\)'
    date_format2 = '20[0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9] ' +
                   '[+-][0-9]{4}'
    date_format3 = '^Date: [A-Z][a-z][a-z], [0-3][0-9] [A-Z][a-z][a-z] 20[0-9][0-9] ' +
                   '[0-2][0-9]:[0-5][0-9]:[0-5][0-9] [+-][0-9]{4}'
    string.gsub(Regexp.new(date_format1), '****-**-** **:**:** +**** (***, ** *** ****)').
           gsub(Regexp.new(date_format2), '****-**-** **:**:** +****').
           gsub(Regexp.new(date_format3), 'Date: ***, ** *** **** **:**:** +****')
  end

  def black_out_mail(mail)
    mail = black_out_sha1(mail)
    mail = black_out_date(mail)
  end

  def test_single_commit
    sample_filename = 'sample_file'

    File.open(@git_dir + sample_filename, 'w') do |file|
      file.puts <<EOF
This is a sample text file.
This file will be modified to make commits.
EOF
    end
    git "add ."
    git 'commit -m "an initial commit"'

    git 'push'

    execute "echo \"This line is appended to commit\" >> #{sample_filename}"
    git 'commit -a -m "a sample commit"'

    git 'push'

    create_default_mailer
    push_mail, commit_mails = nil, []
    each_post_receive_output do |old_revision, new_revision, reference|
      push_mail, commit_mails = process_single_ref_change(old_revision, new_revision, reference)
    end

    File.open("fixtures/test_single_commit") do |file|
      assert_equal(file.read, black_out_mail(commit_mails.shift))
    end
    File.open("fixtures/test_single_commit.push_mail") do |file|
      assert_equal(file.read, black_out_mail(push_mail))
    end
  end

  def test_push_with_merge
    create_default_mailer

    @is_debug_mode = true
    sample_file = 'sample_file'
    sample_branch = 'sample_branch'

    File.open(@git_dir + sample_file, 'w') do |file|
      file.puts <<EOF
This is a sample text file.
This file will be modified to make commits.
Firstly, it'll be appended with some lines in a non-master branch.
Secondly, it'll be prepended and inserted with some lines in the master branch.
Finally, it'll get merged.
EOF
    end
    git "add ."
    git 'commit -m "added an sample text file"'

    git "branch #{sample_branch}"
    git "checkout #{sample_branch}"
    execute "echo \"This line is appended in '#{sample_branch}' branch (1)\" >> #{sample_file}"
    git "commit -a -m \"a sample commit in '#{sample_branch}' branch (1)\""

    git "checkout master"
    execute "sed -i -e '1 s/^/This line is appended in 'master' branch. (1)\\n/' #{sample_file}"
    git "commit -a -m \"a sample commit in 'master' branch (1)\""
    execute "sed -i -e '5 s/^/This line is inserted in 'master' branch. (2)\\n/' #{sample_file}"
    git "commit -a -m \"a sample commit in 'master' branch (2)\""

    git "push origin #{sample_branch} master"

    git "checkout #{sample_branch}"
    execute "echo \"This line is appended in '#{sample_branch}' branch (2)\" >> #{sample_file}"
    git "commit -a -m \"a sample commit in '#{sample_branch}' branch (2)\""
    execute "echo \"This line is appended in '#{sample_branch}' branch (3)\" >> #{sample_file}"
    git "commit -a -m \"a sample commit in '#{sample_branch}' branch (3)\""

    git "checkout master"
    git "merge #{sample_branch}"

    git "push origin master"
    each_post_receive_output do |old_revision, new_revision, reference|
      push_mail, commit_mails = process_single_ref_change(old_revision, new_revision, reference)
      puts push_mail
      commit_mails.each {|mail| puts mail}
      #puts "@@@@@@" + commit_mails.length.to_s
    end
  end
end
