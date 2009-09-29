#!/usr/bin/env ruby

require 'test/unit'
require 'commit-emailer'
require 'tempfile'

class TC_GitCommitMailer < Test::Unit::TestCase
  def initialize(*args)
    @@last_instance = self
    super(*args)
  end

  def execute(command)
    puts "##### cd #{@git_dir} && #{command}"
    result = `(cd #{@git_dir} && #{command}) #< /dev/null > /dev/null 2> /dev/null`
    raise "execute failed." unless $?.exitstatus.zero?
    result
  end

  def git(command)
    execute "git #{command}"
  end

  def make_tmpname
    prefix = 'git-'
    t = Time.now.strftime("%Y%m%d")
    path = "#{prefix}#{t}-#{$$}-#{rand(0x100000000).to_s(36)}/"
  end

  def create_repository
    while File.exist?(@git_dir = Dir.tmpdir + "/" + make_tmpname)
    end
    @repository_dir = @git_dir + ".git/"
    FileUtils.mkdir @git_dir
    git 'init'
    git 'config user.name "User Name"'
    git 'config user.email "user@example.com"'
    #system("chmod +x #{@repository_dir}/hooks/post-receive")
    #system("echo \"cat >> /tmp/post-receive\" >> #{@repository_dir}/hooks/post-receive")
  end

  def delete_repository
    FileUtils.rm_r @git_dir
  end

  def setup
    @is_called = true
    create_repository
  end

  def teardown
    @is_called = false
    #delete_repository
  end

  def zero_revision
    '0' * 40
  end

  def TC_GitCommitMailer.on_send_mail(mail)
    @@last_instance.on_send_mail(mail)
  end

  def on_send_mail(mail)
    raise "on_send_mail is called when not @is_called" unless @is_called
    raise "on_send_mail is called when not @is_processing" unless @is_called

    @mails << mail
  end

  def create_mailer(argv)
    @mailer = GitCommitMailer.parse_options_and_create(argv.split)

    #overrides the default behavior
    def @mailer.send_mail(mail)
      TC_GitCommitMailer.on_send_mail(mail)
    end
  end

  def process_single_ref_change(*args)
    @is_processing = true
    @mails = []
    @mailer.process_single_ref_change(*args)
    @is_processing = false
    @mails
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

    execute "echo \"This line is appended to commit\" >> #{sample_filename}"
    git 'commit -a -m "a sample commit"'

    old_revision = git('rev-parse HEAD~').strip
    new_revision = git('rev-parse HEAD').strip

    create_mailer("--repository=#{@repository_dir} " +
                  "--name=sample-repo " +
                  "--from from@example.com " +
                  "--error-to error@example.com to@example")
    mails = process_single_ref_change(old_revision, new_revision, 'refs/heads/master')

    File.open("fixtures/test_single_commit") do |file|
      assert_equal(file.read + "\n", black_out_mail(mails.shift))
    end
  end
end

