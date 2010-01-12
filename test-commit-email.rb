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

require 'rubygems'
gem 'test-unit'
require 'test/unit'
require 'tempfile'

require 'commit-email'

class GitCommitMailerTest < Test::Unit::TestCase
  DEFAULT_FILE = 'sample_file'
  DEFAULT_FILE_CONTENT = <<END_OF_CONTENT
This is a sample text file.
This file will be modified to make commits.
END_OF_CONTENT

  def execute(command, directory=@working_tree_directory)
    GitCommitMailer.execute(command, directory)
  end

  def sleep_to_advance_timestamp
    sleep 1.1
  end

  def delete_output_from_hook
    FileUtils.rm(@hook_output) if File.exist?(@hook_output)
  end

  def git(command, repository_directory=@repository_directory)
    sleep_to_advance_timestamp if command =~ /\A(commit|merge|tag) /
    delete_output_from_hook if command =~ /\Apush/

    if command =~ /\Ainit/
      execute("git #{command}", repository_directory)
    else
      execute "git --git-dir=#{repository_directory} #{command}"
    end
  end

  def git_commit_new_file(file_name, content, message=nil)
    create_file(file_name, content)

    message ||= "This is a auto-generated commit message: added #{file_name}"
    git "add #{file_name}"
    git "commit -m \"#{message}\""
  end

  def enable_hook
    if File.exist?(@hook + ".sample")
      FileUtils.mv(@hook + ".sample", @hook)
    end
    execute "chmod +x #{@hook}"
  end

  def grab_hook_output
    @hook = @origin_repository_directory + 'hooks/post-receive'
    @hook_output = @hook + '.output'
    enable_hook
    File.open(@hook, 'a') do |file|
      file.puts("cat >> #{@hook_output}")
    end
  end

  def create_origin_repository
    @origin_repository_directory = @test_directory + 'origin/'
    FileUtils.mkdir @origin_repository_directory
    git 'init --bare', @origin_repository_directory
    grab_hook_output
  end

  def config_user_information
    git 'config user.name "User Name"'
    git 'config user.email "user@example.com"'
  end

  def create_working_repository
    @working_tree_directory = @test_directory + 'repo/'
    @repository_directory = @working_tree_directory + '.git/'
    FileUtils.mkdir @working_tree_directory
    git 'init', @working_tree_directory
    config_user_information
    git "remote add origin #{@origin_repository_directory}"
    git "config --add push.default current"
  end

  def temporary_name
    prefix = 'git-'
    t = Time.now.strftime("%Y%m%d")
    path = "#{prefix}#{t}-#{format('%05d',$$)}-#{rand(36**10).to_s(36)}"
  end

  def make_test_directory
    while File.exist?(@test_directory = Dir.tmpdir + "/" + temporary_name + "/")
    end
    FileUtils.mkdir @test_directory
  end

  def create_repositories
    make_test_directory
    create_origin_repository
    create_working_repository
  end

  def delete_repositories
    return if ENV['DEBUG'] == 'yes'
    FileUtils.rm_r @test_directory
  end

  def save_environment_variables(names)
    @saved_environment_variables = {}
    names.each do |name|
      @saved_environment_variables[name] = ENV[name]
      ENV[name] = nil
    end
  end

  def restore_environment_variables
    @saved_environment_variables.each do |name, value|
      ENV[name] = value
    end
  end

  def setup
    @is_debug_mode = true if ENV['DEBUG'] == 'yes'
    save_environment_variables(['GIT_AUTHOR_NAME',
                                'GIT_AUTHOR_EMAIL',
                                'GIT_COMMITTER_NAME',
                                'GIT_COMMITTER_EMAIL',
                                'EMAIL'])
    create_repositories
  end

  def teardown
    delete_repositories
    restore_environment_variables
  end

  def expand_path(file_name)
    @working_tree_directory + file_name
  end

  def move_file(old_file_name, new_file_name)
    FileUtils.mv(@working_tree_directory + old_file_name,
                 @working_tree_directory + new_file_name)
  end

  def copy_file(file_name, copied_file_name)
    FileUtils.cp(@working_tree_directory + file_name,
                 @working_tree_directory + copied_file_name)
  end

  def remove_file(file_name)
    FileUtils.rm(@working_tree_directory + file_name)
  end

  def create_file(file_name, content)
    File.open(expand_path(file_name), 'w') do |file|
      file.puts(content)
    end
  end

  def create_directory(directory_name)
    FileUtils.mkdir expand_path(directory_name)
  end

  def prepend_line(file_name, line)
    content = line + "\n" + IO.read(expand_path(file_name))
    create_file(file_name, content)
  end

  def append_line(file_name, line)
    content = IO.read(expand_path(file_name)) + line + "\n"
    create_file(file_name, content)
  end

  def insert_line(file_name, line, offset)
    content = IO.readlines(expand_path(file_name)).insert(offset, line + "\n").join
    create_file(file_name, content)
  end

  def edit_file(file_name)
    lines = IO.readlines(expand_path(file_name))
    content = yield(lines).join
    create_file(file_name, content)
  end

  def create_mailer(argv)
    p argv.split if ENV['DEBUG']
    @mailer = GitCommitMailer.parse_options_and_create(argv.split)
  end

  def create_default_mailer
    create_mailer("--repository=#{@origin_repository_directory} " +
                  "--name=sample-repo " +
                  "--from from@example.com " +
                  "--error-to error@example.com to@example")
  end

  def each_reference_change
    begin
      File.open(@hook_output, 'r') do |file|
        while line = file.gets
          old_revision, new_revision, reference = line.split
          puts "#{old_revision} #{new_revision} #{reference}" if ENV['DEBUG']
          yield old_revision, new_revision, reference
        end
      end
    rescue Errno::ENOENT
    end
  end

  def process_reference_change(*args)
    @push_mail, @commit_mails = @mailer.process_reference_change(*args)
  end

  def last_mails
    push_mail, commit_mails = nil, []
    each_reference_change do |old_revision, new_revision, reference|
      push_mail, commit_mails = process_reference_change(old_revision, new_revision, reference)
    end
    [push_mail, commit_mails]
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

  def read_from_fixture_directory(file)
    IO.read('fixtures/' + file)
  end

  def expected_rss(file)
    read_from_fixture_directory(file)
  end

  def expected_mail(file)
    read_from_fixture_directory(file)
  end

  @@header_regexp = /^(.|\n)*?\n\n/
  def header_section(mail)
    mail[@@header_regexp]
  end

  def body_section(mail)
    mail.sub(@@header_regexp, '')
  end

  def assert_mail(expected_mail_file_name, tested_mail)
    assert_equal(header_section(expected_mail(expected_mail_file_name)),
                 header_section(black_out_mail(tested_mail)))
    assert_equal(body_section(expected_mail(expected_mail_file_name)),
                 body_section(black_out_mail(tested_mail)))
  end

  def assert_rss(expected_rss_file_path, actual_rss_file_path)
    expected = expected_rss(expected_rss_file_path)
    actual = IO.read(actual_rss_file_path) + "\n"
    dc_date = '(<dc:date>20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.)' +
              '([0-9]{0,6})(\+09:00<\/dc:date>)'
    actual.gsub!(Regexp.new(dc_date)) do
      $1 + format('%06d', $2.to_i) + $3
    end
    actual.sub!(/<rdf:RDF(([ \n]|xmlns[^ \n]*)*)>/, '<rdf:RDF>')

    index = 0
    actual = actual.scan(/(.|\n)/).collect do |character|
      expected_character = expected[index].chr
      index += 1
      if expected_character == '*'
        expected_character
      else
        character
      end
    end.join

    assert_equal(expected, actual)
  end

  def test_single_commit
    create_default_mailer
    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")

    git 'push origin master'

    push_mail, commit_mails = last_mails

    assert_mail('test_single_commit.push_mail', push_mail)
    assert_mail('test_single_commit', commit_mails[0])
  end

  def test_rss
    rss_file_path = "#{@test_directory}sample-repo.rss"
    create_mailer("--repository=#{@origin_repository_directory} " +
                  "--name=sample-repo " +
                  "--from from@example.com " +
                  "--error-to error@example.com to@example " +
                  "--repository-uri http://git.example.com/sample-repo.git " +
                  "--rss-uri file://#{@origin_repository_directory} " +
                  "--rss-path #{rss_file_path}")

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    each_reference_change do |old_revision, new_revision, reference|
      process_reference_change(old_revision, new_revision, reference)
    end

    assert_rss('test_rss.rss', rss_file_path)
  end

  def test_show_path
    create_mailer("--repository=#{@origin_repository_directory} " +
                  "--name=sample-repo " +
                  "--from from@example.com " +
                  "--error-to error@example.com to@example " +
                  "--show-path")

    create_directory("mm")
    create_file("mm/memory.c", "/* memory related code goes here */")
    create_directory("drivers")
    create_file("drivers/PLACEHOLDER", "just to make git recognize drivers directory")
    git "add ."
    git "commit -m %s" % Shellwords.escape("added mm and drivers directory")
    git "push"

    append_line("mm/memory.c", "void *malloc(size_t size);")
    git "commit -a -m %s" % Shellwords.escape("added malloc declaration")
    git "push"

    _, commit_mails = last_mails
    assert_mail('test_show_path', commit_mails.first)
  end

  def create_mailer_with_no_diff_option
    create_mailer("--repository=#{@origin_repository_directory} " +
                  "--name=sample-repo " +
                  "--from from@example.com " +
                  "--error-to error@example.com to@example " +
                  "--no-diff")
  end

  def test_no_diff
    create_mailer_with_no_diff_option

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")

    append_line(DEFAULT_FILE, "an appended line.")
    git "commit -a -m %s" % Shellwords.escape("appended a line")

    git 'push'
    _, commit_mails = last_mails

    assert_mail('test_no_diff.1', commit_mails.shift)
    assert_mail('test_no_diff.2', commit_mails.shift)
  end

  def test_no_diff_rename
    create_mailer_with_no_diff_option

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    move_file(DEFAULT_FILE, "renamed.txt")
    git "add ."
    git "commit -a -m %s" % Shellwords.escape("renamed a file")

    git 'push'
    _, commit_mails = last_mails
    assert_mail('test_no_diff_rename', commit_mails.shift)
  end

  def test_no_diff_copy
    create_mailer_with_no_diff_option

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    append_line(DEFAULT_FILE, "hi.")
    copy_file(DEFAULT_FILE, "copied.txt")
    git "add ."
    git "commit -a -m %s" % Shellwords.escape("copied a file")

    git 'push'
    _, commit_mails = last_mails
    assert_mail('test_no_diff_copy', commit_mails.shift)
  end

  def test_no_diff_remove
    create_mailer_with_no_diff_option

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    remove_file(DEFAULT_FILE)
    git "commit -a -m %s" % Shellwords.escape("removed a file")
    git 'push'
    _, commit_mails = last_mails

    assert_mail('test_no_diff_remove', commit_mails.shift)
  end

  def test_rename
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    move_file(DEFAULT_FILE, "renamed.txt")
    git "add ."
    git "commit -a -m %s" % Shellwords.escape("renamed a file")

    git 'push'
    _, commit_mails = last_mails

    assert_mail('test_rename', commit_mails.shift)
  end

  def test_rename_with_modification
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    renamed_file_name = "renamed.txt"
    move_file(DEFAULT_FILE, renamed_file_name)
    append_line(renamed_file_name, "Hello.")
    git "add ."
    git "commit -a -m %s" % Shellwords.escape("renamed a file")

    git 'push'
    _, commit_mails = last_mails

    assert_mail('test_rename_with_modification', commit_mails.shift)
  end

  def test_copy
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'
    append_line(DEFAULT_FILE, "hi.")

    copy_file(DEFAULT_FILE, "renamed.txt")
    git "add ."
    git "commit -a -m %s" % Shellwords.escape("copied a file")

    git 'push'
    _, commit_mails = last_mails

    assert_mail('test_copy', commit_mails.shift)
  end

  def test_remove
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    remove_file(DEFAULT_FILE)
    git "commit -a -m %s" % Shellwords.escape("removed a file")
    git 'push'
    _, commit_mails = last_mails

    assert_mail('test_remove', commit_mails.shift)
  end

  def test_copy_with_modification
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'
    append_line(DEFAULT_FILE, "hi.")

    copied_file_name = "copied.txt"
    copy_file(DEFAULT_FILE, copied_file_name)
    append_line(copied_file_name, "Hello.")
    git "add ."
    git "commit -a -m %s" % Shellwords.escape("copied a file")

    git 'push'
    _, commit_mails = last_mails

    assert_mail('test_copy_with_modification', commit_mails.shift)
  end

  def test_max_size
    create_mailer("--repository=#{@origin_repository_directory} " +
                  "--name=sample-repo " +
                  "--from from@example.com " +
                  "--error-to error@example.com to@example " +
                  "--max-size=100B")

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    push_mail, _ = last_mails

    assert_mail('test_max_size.push_mail', push_mail)
  end

  def test_push_with_merge
    create_default_mailer
    sample_branch = 'sample_branch'

    file_content = <<EOF
This is a sample text file.
This file will be modified to make commits.
Firstly, it'll be appended with some lines in a non-master branch.
Secondly, it'll be prepended and inserted with some lines in the master branch.
Finally, it'll get merged.
EOF
    git_commit_new_file(DEFAULT_FILE, file_content, "added a sample text file")

    git "branch #{sample_branch}"
    git "checkout #{sample_branch}"
    append_line(DEFAULT_FILE, "This line is appended in '#{sample_branch}' branch (1)")
    git "commit -a -m \"a sample commit in '#{sample_branch}' branch (1)\""
    git "tag -a -m 'This is a sample tag' sample_tag"

    git "checkout master"
    prepend_line(DEFAULT_FILE, "This line is appended in 'master' branch. (1)")
    git "commit -a -m \"a sample commit in 'master' branch (1)\""
    insert_line(DEFAULT_FILE, "This line is inserted in 'master' branch. (2)", 5)
    git "commit -a -m \"a sample commit in 'master' branch (2)\""

    git "push --tags origin #{sample_branch} master"

    git "checkout #{sample_branch}"
    append_line(DEFAULT_FILE, "This line is appended in '#{sample_branch}' branch (2)")
    git "commit -a -m \"a sample commit in '#{sample_branch}' branch (2)\""
    append_line(DEFAULT_FILE, "This line is appended in '#{sample_branch}' branch (3)")
    git "commit -a -m \"a sample commit in '#{sample_branch}' branch (3)\""

    git "checkout master"
    git "merge #{sample_branch}"

    git "push origin master #{sample_branch}"

    pushes = []
    each_reference_change do |old_revision, new_revision, reference|
      pushes << process_reference_change(old_revision, new_revision, reference)
    end

    master_ref_change = pushes[0]
    master_push_mail = master_ref_change[0]
    master_commit_mails = master_ref_change[1]

    assert_mail('test_push_with_merge.push_mail', master_push_mail)
    assert_equal(4, master_commit_mails.length)
    assert_mail('test_push_with_merge.1', master_commit_mails[0])
    assert_mail('test_push_with_merge.2', master_commit_mails[1])
    assert_mail('test_push_with_merge.3', master_commit_mails[2])
  end

  def test_diffs_with_trailing_spaces
    create_default_mailer

    file_content = <<EOF
This is a sample text file.
This file will be modified to make commits.
    
In the above line, I intentionally left some spaces.
EOF
    git_commit_new_file(DEFAULT_FILE, file_content, "added a sample file")
    git 'push origin master'

    edit_file(DEFAULT_FILE) do |lines|
      lines.collect do |line|
        line.rstrip + "\n"
      end
    end
    git 'commit -a -m "removed trailing spaces"'

    git 'push'

    push_mail, commit_mails = last_mails

    assert_mail('test_diffs_with_trailing_spaces', commit_mails[0])
  end

  def test_diffs_with_multiple_hunks
    create_default_mailer

    file_content = <<EOF
This is a sample text file.
This file will be modified to make commits.

In the above line, I intentionally left some spaces.
some filler text to make two hunks with diff
some filler text to make two hunks with diff
some filler text to make two hunks with diff
some filler text to make two hunks with diff
some filler text to make two hunks with diff
some filler text to make two hunks with diff
some filler text to make two hunks with diff
EOF
    git_commit_new_file(DEFAULT_FILE, file_content, "added a sample file")
    git 'push origin master'

    prepend_line(DEFAULT_FILE, 'a prepended line')
    append_line(DEFAULT_FILE, 'an appended line')
    git 'commit -a -m "edited to happen multiple hunks"'

    git 'push'

    push_mail, commit_mails = last_mails

    assert_mail('test_diffs_with_multiple_hunks', commit_mails[0])
  end

  def test_diffs_with_multiple_files
    create_default_mailer

    2.times do |i|
      file_name = "file_#{i.to_s}"
      file_content = "text in #{file_name}"
      commit_log = "added #{file_name}"
      create_file(file_name, file_content)
      git "add #{file_name}"
    end
    git "commit -a -m 'added multiple files'"
    git 'push origin master'

    push_mail, commit_mails = last_mails

    assert_mail('test_diffs_with_multiple_files', commit_mails[0])
  end

  def test_nested_merges
    create_default_mailer
    first_branch = 'first_branch'
    second_branch = 'second_branch'

    file_content = <<EOF
This is a sample text file.
This file will be modified to make commits.
This line is needed to assist the auto-merge algorithm.
EOF
    git_commit_new_file(DEFAULT_FILE, file_content, "added a sample file")
    git 'push origin master'

    git "branch #{first_branch}"
    git "checkout #{first_branch}"
    append_line(DEFAULT_FILE, "This line is appended in '#{first_branch}' branch.")
    git "commit -a -m \"a sample commit in '#{first_branch}' branch\""
    git "push"

    git "checkout master"
    edit_file(DEFAULT_FILE) do |lines|
      lines[0].sub!(/This/, 'THIS')
      lines
    end
    git "commit -a -m \"a sample commit in master branch: This => THIS\""
    git "push"

    git "branch #{second_branch}"
    git "checkout #{second_branch}"
    prepend_line(DEFAULT_FILE, "This line is prepnded in '#{second_branch}' branch.")
    git "commit -a -m \"a sample commit in '#{second_branch}' branch\""
    git "push"

    git "checkout master"
    edit_file(DEFAULT_FILE) do |lines|
      lines[1].sub!(/file/, 'FILE')
      lines
    end
    git "commit -a -m \"a sample commit in master branch: file => FILE\""
    git "push"


    git "checkout #{first_branch}"
    git "merge #{second_branch}"

    git "checkout master"
    git "merge #{first_branch}"
    git "push"

    push_mail, commit_mails = last_mails

    assert_mail('test_nested_merges.push_mail', push_mail)
    assert_mail('test_nested_merges.1', commit_mails[0])
    assert_mail('test_nested_merges.2', commit_mails[1])
    assert_mail('test_nested_merges.3', commit_mails[2])
    assert_mail('test_nested_merges.4', commit_mails[3])
    assert_mail('test_nested_merges.5', commit_mails[4])
  end

  def test_non_ascii_file_name
    create_default_mailer
    git_commit_new_file("日本語.txt", "日本語の文章です。", "added a file with japanese file name")
    git "push origin master"

    push_mail, commit_mails = last_mails

    assert_mail('test_non_ascii_file_name', commit_mails[0])
  end

  def test_long_word_in_commit_subject
    create_default_mailer
    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "x" * 60)

    git 'push origin master'

    push_mail, commit_mails = last_mails

    assert_mail('test_long_word_in_commit_subject', commit_mails[0])
  end

  def prepare_to_tag
    create_default_mailer
    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "sample commit")
    git "push"
  end

  def test_create_annotated_tag
    prepare_to_tag

    git "tag -a -m \'sample tag\' v0.0.1"
    git "push --tags"

    push_mail, commit_mails = last_mails

    assert_mail('test_create_annotated_tag.push_mail', push_mail)
  end

  def test_update_annotated_tag
    prepare_to_tag

    git "tag -a -m \'sample tag\' v0.0.1"
    git "push --tags"
    git "tag -a -f -m \'sample tag\' v0.0.1"
    git "push --tags"

    push_mail, commit_mails = last_mails

    assert_not_nil(push_mail)
    assert_mail('test_update_annotated_tag.push_mail', push_mail)
  end

  def test_short_log
    prepare_to_tag

    append_line(DEFAULT_FILE, 'a line')
    git "commit -m 'release v0.0.1' -a"
    git "push"
    git "tag -a -m \'sample tag (v0.0.1)\' v0.0.1"
    git "push --tags"
    append_line(DEFAULT_FILE, 'a line')
    git "commit -m 'last tweaks' -a"
    append_line(DEFAULT_FILE, 'a line')
    git "commit -m 'release v0.0.2' -a"
    git "push"
    git "tag -a -f -m \'sample tag (v0.0.2)\' v0.0.2"
    git "push --tags"

    push_mail, commit_mails = last_mails

    assert_not_nil(push_mail)
    assert_mail('test_short_log.push_mail', push_mail)
  end

  def test_delete_annotated_tag
    prepare_to_tag

    git "tag -a -m \'sample tag\' v0.0.1"
    git "push --tags"
    git "tag -d v0.0.1"
    git "push --tags origin :refs/tags/v0.0.1"

    push_mail, commit_mails = last_mails

    assert_not_nil(push_mail)
    assert_mail('test_delete_annotated_tag.push_mail', push_mail)
  end

  def test_create_unannotated_tag
    prepare_to_tag

    git "tag v0.0.1"
    git "push --tags"

    push_mail, commit_mails = last_mails

    assert_mail('test_create_unannotated_tag.push_mail', push_mail)
  end

  def test_update_unannotated_tag
    prepare_to_tag

    git "tag v0.0.1"
    git "push --tags"
    append_line(DEFAULT_FILE, 'a line')
    git "commit -m 'new commit' -a"
    git "tag -f v0.0.1"
    git "push --tags"

    push_mail, commit_mails = last_mails

    assert_mail('test_update_unannotated_tag.push_mail', push_mail)
  end

  def test_delete_unannotated_tag
    prepare_to_tag

    git "tag v0.0.1"
    git "push --tags"
    git "tag -d v0.0.1"
    git "push --tags origin :refs/tags/v0.0.1"

    push_mail, commit_mails = last_mails

    assert_not_nil(push_mail)
    assert_mail('test_delete_unannotated_tag.push_mail', push_mail)
  end
end
