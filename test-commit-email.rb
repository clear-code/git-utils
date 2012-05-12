#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
#
# Copyright (C) 2009  Ryo Onodera <onodera@clear-code.com>
# Copyright (C) 2011  Kouhei Sutou <kou@clear-code.com>
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

$VERBOSE = true

require 'rubygems'
gem 'test-unit'
require 'test/unit'
require 'tempfile'

require 'commit-email'

module Constants
  DEFAULT_FILE = 'sample_file'
  DEFAULT_FILE_CONTENT = <<END_OF_CONTENT
This is a sample text file.
This file will be modified to make commits.
END_OF_CONTENT
  DATE = Time.at(1263363342)
  DATE_OPTION = "--date=#{DATE.to_s}"
  PUSH_ERROR_MESSAGE = Regexp.new(<<END_OF_ERROR_MESSAGE)
No refs in common and none specified; doing nothing.
Perhaps you should specify a branch such as 'master'.
fatal: The remote end hung up unexpectedly
error: failed to push some refs to '/tmp/git-[0-9]{8}-[0-9]{5}-[0-9a-z]{10}/origin/'
END_OF_ERROR_MESSAGE
end

module GitCommitMailerDiffTest
  include Constants
  def test_trailing_spaces
    create_default_mailer

    file_content = <<EOF
This is a sample text file.
This file will be modified to make commits.
    
In the above line, I intentionally left some spaces.
EOF
    git_commit_new_file(DEFAULT_FILE, file_content, "added a sample file")
    git 'push'

    edit_file(DEFAULT_FILE) do |lines|
      lines.collect do |line|
        line.rstrip + "\n"
      end
    end
    git 'commit -a -m "removed trailing spaces"'

    git 'push'

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_diffs_with_trailing_spaces', commit_mails[0])
  end

  def test_multiple_hunks
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
    git 'push'

    prepend_line(DEFAULT_FILE, 'a prepended line')
    append_line(DEFAULT_FILE, 'an appended line')
    git 'commit -a -m "edited to happen multiple hunks"'

    git 'push'

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_diffs_with_multiple_hunks', commit_mails[0])
  end

  def test_multiple_files
    create_default_mailer

    2.times do |i|
      file_name = "file_#{i.to_s}"
      file_content = "text in #{file_name}"
      commit_log = "added #{file_name}"
      create_file(file_name, file_content)
      git "add #{file_name}"
    end
    git "commit -a -m 'added multiple files'"
    git 'push'

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_diffs_with_multiple_files', commit_mails[0])
  end

  def test_8digits_object_id
    create_default_mailer

    # Use find-duplicated-7digits-short-object-id-contents.rb for finding
    # duplicated 7digits short object ID contents.
    # Here are one of duplciated pair:
    #   % echo rpi | git hash-object --stdin
    #   61aaae353841d282eb4cc29b31e8abe76d362f0c
    #   % echo adua | git hash-object --stdin
    #   61aaae3eff35760a9a0612c744e1f19e57e78e9c

    duplicated_7digits_short_object_id_content1 = "rpi"
    duplicated_7digits_short_object_id_content2 = "adua"
    create_file(duplicated_7digits_short_object_id_content1,
                duplicated_7digits_short_object_id_content1)
    create_file(duplicated_7digits_short_object_id_content2,
                duplicated_7digits_short_object_id_content2)
    git("commit -a -m 'Add duplicated 7digits short object ID contents'")
    git("push")

    create_file(duplicated_7digits_short_object_id_content1, "new content")
    git("commit -a -m 'Change a duplicated 7digits short object ID content'")
    git("push")

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail("test_diffs_with_8digits_object_id", commit_mails[0])
  end
end

module GitCommitMailerFileManipulationTest
  include Constants
  def test_edit
    create_default_mailer
    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")

    git 'push'

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_single_commit.push_mail', push_mail)
    assert_mail('test_single_commit', commit_mails[0])
  end

  def test_rename
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    move_file(DEFAULT_FILE, "renamed.txt")
    git "commit -a -m %s" % shell_escape("renamed a file")

    git 'push'
    _, commit_mails = get_mails_of_last_push

    assert_mail('test_rename', commit_mails.shift)
  end

  def test_rename_with_modification
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    renamed_file_name = "renamed.txt"
    move_file(DEFAULT_FILE, renamed_file_name)
    append_line(renamed_file_name, "Hello.")
    git "commit -a -m %s" % shell_escape("renamed a file")

    git 'push'
    _, commit_mails = get_mails_of_last_push

    assert_mail('test_rename_with_modification', commit_mails.shift)
  end

  def test_copy
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'
    append_line(DEFAULT_FILE, "hi.")

    copy_file(DEFAULT_FILE, "copied.txt")
    git "commit -a -m %s" % shell_escape("copied a file")

    git 'push'
    _, commit_mails = get_mails_of_last_push

    assert_mail('test_copy', commit_mails.shift)
  end

  def test_copy_with_modification
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'
    append_line(DEFAULT_FILE, "hi.")

    copied_file_name = "copied.txt"
    copy_file(DEFAULT_FILE, copied_file_name)
    append_line(copied_file_name, "Hello.")
    git "commit -a -m %s" % shell_escape("copied a file")

    git 'push'
    _, commit_mails = get_mails_of_last_push

    assert_mail('test_copy_with_modification', commit_mails.shift)
  end

  def test_remove
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    remove_file(DEFAULT_FILE)
    git "commit -a -m %s" % shell_escape("removed a file")
    git 'push'
    _, commit_mails = get_mails_of_last_push

    assert_mail('test_remove', commit_mails.shift)
  end

  def test_file_mode
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    change_file_mode(0777, DEFAULT_FILE)
    git "commit -a -m %s" % shell_escape("changed a file mode")

    git 'push'
    _, commit_mails = get_mails_of_last_push

    assert_mail('test_file_mode', commit_mails.shift)
  end

  def test_file_type_change
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    FileUtils.rm_r(expand_path(DEFAULT_FILE))
    FileUtils.ln_s("../../referenced.txt", expand_path(DEFAULT_FILE))
    git "commit -a -m %s" % shell_escape("changed a file type")
    git 'push'

    _, commit_mails = get_mails_of_last_push

    assert_mail('test_file_type_change', commit_mails.shift)
  end
end

module GitCommitMailerNoDiffTest
  include Constants
  def test_edit
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")

    append_line(DEFAULT_FILE, "an appended line.")
    git "commit -a -m %s" % shell_escape("appended a line")

    git 'push'
    _, commit_mails = get_mails_of_last_push

    assert_mail('test_no_diff.1', commit_mails.shift)
    assert_mail('test_no_diff.2', commit_mails.shift)
  end

  def test_rename
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    move_file(DEFAULT_FILE, "renamed.txt")
    git "commit -a -m %s" % shell_escape("renamed a file")

    git 'push'
    _, commit_mails = get_mails_of_last_push
    assert_mail('test_no_diff_rename', commit_mails.shift)
  end

  def test_copy
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    append_line(DEFAULT_FILE, "hi.")
    copy_file(DEFAULT_FILE, "copied.txt")
    git "commit -a -m %s" % shell_escape("copied a file")

    git 'push'
    _, commit_mails = get_mails_of_last_push
    assert_mail('test_no_diff_copy', commit_mails.shift)
  end

  def test_remove
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    remove_file(DEFAULT_FILE)
    git "commit -a -m %s" % shell_escape("removed a file")
    git 'push'
    _, commit_mails = get_mails_of_last_push

    assert_mail('test_no_diff_remove', commit_mails.shift)
  end
end

module GitCommitMailerTagTest
  include Constants
  def prepare_to_tag
    create_default_mailer
    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "sample commit")
    git "push"
  end

  def test_create_annotated_tag
    prepare_to_tag

    git "tag -a -m \'sample tag\' v0.0.1"
    git "push --tags"

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_create_annotated_tag.push_mail', push_mail)
  end

  def test_update_annotated_tag
    prepare_to_tag

    git "tag -a -m \'sample tag\' v0.0.1"
    git "push --tags"
    git "tag -a -f -m \'sample tag\' v0.0.1"
    git "push --tags"

    push_mail, commit_mails = get_mails_of_last_push

    assert_not_nil(push_mail)
    assert_mail('test_update_annotated_tag.push_mail', push_mail)
  end

  def test_delete_annotated_tag
    prepare_to_tag

    git "tag -a -m \'sample tag\' v0.0.1"
    git "push --tags"
    git "tag -d v0.0.1"
    git "push --tags origin :refs/tags/v0.0.1"

    push_mail, commit_mails = get_mails_of_last_push

    assert_not_nil(push_mail)
    assert_mail('test_delete_annotated_tag.push_mail', push_mail)
  end

  def test_create_unannotated_tag
    prepare_to_tag

    git "tag v0.0.1"
    git "push --tags"

    push_mail, commit_mails = get_mails_of_last_push

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

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_update_unannotated_tag.push_mail', push_mail)
  end

  def test_delete_unannotated_tag
    prepare_to_tag

    git "tag v0.0.1"
    git "push --tags"
    git "tag -d v0.0.1"
    git "push --tags origin :refs/tags/v0.0.1"

    push_mail, commit_mails = get_mails_of_last_push

    assert_not_nil(push_mail)
    assert_mail('test_delete_unannotated_tag.push_mail', push_mail)
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

    push_mail, commit_mails = get_mails_of_last_push

    assert_not_nil(push_mail)
    assert_mail('test_short_log.push_mail', push_mail)
  end
end

module GitCommitMailerMergeTest
  include Constants
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
    git 'push'

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

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_nested_merges.push_mail', push_mail)
    assert_mail('test_nested_merges.1', commit_mails[0])
    assert_mail('test_nested_merges.2', commit_mails[1])
    assert_mail('test_nested_merges.3', commit_mails[2])
    assert_mail('test_nested_merges.4', commit_mails[3])
    assert_mail('test_nested_merges.5', commit_mails[4])
  end
end

module GitCommitMailerNonAsciiTest
  include Constants
  def test_file_name
    create_default_mailer
    git_commit_new_file("日本語.txt", "日本語の文章です。", "added a file with japanese file name")
    git "push"

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_non_ascii_file_name', commit_mails[0])
  end

  def test_commit_subject
    create_default_mailer
    git_commit_new_file("日本語.txt", "日本語の文章です。", "ファイルを追加")
    git "push"

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_non_ascii_commit_subject', commit_mails[0])
  end

  def test_move_file
    create_default_mailer
    git_commit_new_file("日本語.txt", "日本語の文章です。", "added a file with japanese file name")
    git "push"
    move_file("日本語.txt", "日本語です.txt")
    git "commit -a -m \"日本語.txt -> 日本語です.txt\""
    git "push"

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_move_non_ascii_file', commit_mails[0])
  end

  def test_long_word_in_commit_subject
    create_default_mailer
    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "x" * 60)

    git 'push'

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_long_word_in_commit_subject', commit_mails[0])
  end
end

module GitCommitMailerOptionTest
  include Constants
  def test_rss
    rss_file_path = "#{@test_directory}sample-repo.rss"

    rss_options = ["--repository-uri=http://git.example.com/sample-repo.git",
                   "--rss-uri=file://#{@origin_repository_directory}",
                   "--rss-path=#{rss_file_path}"]
    set_additional_default_mailer_option(*rss_options)
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    each_reference_change do |old_revision, new_revision, reference|
      process_reference_change(old_revision, new_revision, reference)
    end

    assert_rss('test_rss.rss', rss_file_path)
  end


  def test_utf7
    set_additional_default_mailer_option("--utf7")
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_utf7.push_mail', push_mail)
    assert_mail('test_utf7', commit_mails.first)
  end

  def test_show_path
    set_additional_default_mailer_option("--show-path")
    create_default_mailer

    create_directory("mm")
    create_file("mm/memory.c", "/* memory related code goes here */")
    create_directory("drivers")
    create_file("drivers/PLACEHOLDER", "just to make git recognize drivers directory")
    git "commit -m %s" % shell_escape("added mm and drivers directory")
    git "push"

    append_line("mm/memory.c", "void *malloc(size_t size);")
    git "commit -a -m %s" % shell_escape("added malloc declaration")
    git "push"

    _, commit_mails = get_mails_of_last_push
    assert_mail('test_show_path', commit_mails.first)
  end

  def test_max_size
    set_additional_default_mailer_option("--max-size=100B")
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    push_mail, _ = get_mails_of_last_push

    assert_mail('test_max_size.push_mail', push_mail)
  end

  def test_sender
    set_additional_default_mailer_option("--sender=sender@example.com")
    create_default_mailer

    git_commit_new_file(DEFAULT_FILE, DEFAULT_FILE_CONTENT, "an initial commit")
    git 'push'

    push_mail, commit_mails = get_mails_of_last_push

    assert_mail('test_sender.push_mail', push_mail)
    assert_mail('test_sender', commit_mails.first)
  end
end

module HookModeTest
  module Utils
    include Constants
    def execute(command, directory=@working_tree_directory)
      GitCommitMailer.execute(command, directory)
    end

    def shell_escape(string)
      GitCommitMailer.shell_escape(string)
    end

    def advance_timestamp
      @timestamp += 1
    end

    def delete_output_from_hook
      FileUtils.rm(@hook_output) if File.exist?(@hook_output)
    end

    def set_timestamp
      ENV["GIT_AUTHOR_DATE"] = @timestamp.to_s
      ENV["GIT_COMMITTER_DATE"] = @timestamp.to_s
    end

    def reset_timestamp
      ENV.delete("GIT_AUTHOR_DATE")
      ENV.delete("GIT_COMMITTER_DATE")
    end

    def git(command, repository_directory=@repository_directory)
      if command =~ /\Ainit/
        execute("git #{command}", repository_directory)
      else
        if command =~ /\A(commit|merge|tag) /
          advance_timestamp
          set_timestamp
        end
        delete_output_from_hook if command =~ /\Apush/

        begin
          execute "git --git-dir=#{repository_directory} #{command}"
        rescue Exception => exception
          if command == "push" and exception.message =~ PUSH_ERROR_MESSAGE
            command += " origin master"
            retry
          else
            raise
          end
        end
        reset_timestamp
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
      else
        FileUtils.touch(@hook)
      end
      FileUtils.chmod(0755, @hook)
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
      time = Time.now.strftime("%Y%m%d")
      path = "git-#{time}-#{format('%05d', $$)}-" +
             "#{10.times.collect{rand(36).to_s(36)}.join}"
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
        ENV.delete(name)
      end
    end

    def restore_environment_variables
      @saved_environment_variables.each do |name, value|
        ENV[name] = value unless value.nil?
      end
    end

    def setup
      @is_debug_mode = true if ENV['DEBUG'] == 'yes'
      save_environment_variables(['GIT_AUTHOR_NAME',
                                  'GIT_AUTHOR_EMAIL',
                                  'GIT_COMMITTER_NAME',
                                  'GIT_COMMITTER_EMAIL',
                                  'EMAIL'])
      @timestamp = DATE
      @working_tree_directory = ""
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
      FileUtils.mv(expand_path(old_file_name), expand_path(new_file_name))
      git "add %s" % shell_escape(new_file_name)
    end

    def copy_file(file_name, copied_file_name)
      FileUtils.cp(expand_path(file_name), expand_path(copied_file_name))
      git "add %s" % shell_escape(copied_file_name)
    end

    def remove_file(file_name)
      FileUtils.rm(expand_path(file_name))
    end

    def change_file_mode(file_mode, file_name)
      FileUtils.chmod(file_mode, expand_path(file_name))
    end

    def create_file(file_name, content)
      File.open(expand_path(file_name), 'w') do |file|
        file.puts(content)
      end
      git "add %s" % shell_escape(file_name)
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

    def create_mailer(*arguments)
      p arguments if ENV['DEBUG']
      @mailer = GitCommitMailer.parse_options_and_create(arguments)
    end

    def set_additional_default_mailer_option(*options)
      @default_mailer_options = options
    end

    def create_default_mailer
      if not defined?(@default_mailer_options)
        options = nil
      else
        options = @default_mailer_options
      end

      create_mailer("--repository=#{@origin_repository_directory}",
                    "--name=sample-repo",
                    "--error-to=error@example.com",
                    DATE_OPTION,
                    "to@example", *options)
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

    def get_mails_of_last_push
      push_mail, commit_mails = nil, []
      each_reference_change do |old_revision, new_revision, reference|
        push_mail, commit_mails = process_reference_change(old_revision, new_revision, reference)
      end
      [push_mail, commit_mails]
    end

    def read_from_fixture_directory(file)
      file = IO.read('fixtures/' + file)
      file.force_encoding("UTF-8") if file.respond_to? :force_encoding
      file
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

    def assert_header(expected_header, actual_header)
      assert_equal(expected_header, actual_header)
    end

    def assert_body(expected_body, actual_body)
      assert_equal(expected_body, actual_body)
    end

    def assert_mail(expected_mail_file_name, tested_mail)
      begin
        assert_header(header_section(expected_mail(expected_mail_file_name)),
                      header_section(tested_mail))
        assert_body(body_section(expected_mail(expected_mail_file_name)),
                    body_section(tested_mail))
      rescue
        puts tested_mail if ENV['DEBUG']
        raise
      end
    end

    def assert_rss(expected_rss_file_path, actual_rss_file_path)
      expected = expected_rss(expected_rss_file_path)
      actual = IO.read(actual_rss_file_path) + "\n"

      channel_regexp = '<channel rdf:about="file:///tmp/git-[0-9]{8}-[0-9]{5}-' +
                       '[0-9a-z]{10}/origin/">'
      [expected, actual].each do |rss|
        rss.sub!(/<rdf:RDF(([ \n]|xmlns[^ \n]*)*)>/, '<rdf:RDF>')
        rss.sub!(/<dc:date>.*?<\/dc:date>/, '<dc:date/>')
        rss.sub!(/#{channel_regexp}/,
                 '<channel rdf:about="file:///tmp/.../origin/">')
      end
      assert_equal(expected, actual)
    end
  end

  class GitCommitMailerDiffTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerDiffTest
  end

  class GitCommitMailerFileManipulationTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerFileManipulationTest
  end

  class GitCommitMailerNoDiffTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerNoDiffTest

    def initialize(*args)
      super(*args)
      set_additional_default_mailer_option("--no-diff")
    end
  end

  class GitCommitMailerTagTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerTagTest
  end

  class GitCommitMailerMergeTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerMergeTest
  end

  class GitCommitMailerNonAsciiTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerNonAsciiTest
  end

  class GitCommitMailerOptionTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerOptionTest
  end
end

module TrackRemoteModeTest
  module Utils
    include HookModeTest::Utils
    alias old_git git
    def git(command, *args)
      if command =~ /\Apush/
        git "fetch --force", @remote_tracking_repository
      end
      old_git(command, *args)
    end

    def create_remote_tracking_repository
      @remote_tracking_repository = @test_directory + 'remote-tracking-repo/'
      FileUtils.mkdir @remote_tracking_repository
      git 'init --bare', @remote_tracking_repository
      git "remote add origin #{@origin_repository_directory}", @remote_tracking_repository
    end

    alias old_create_repositories create_repositories
    def create_repositories
      old_create_repositories
      create_remote_tracking_repository
    end

    def create_default_mailer
      if not defined?(@default_mailer_options)
        options = nil
      else
        options = @default_mailer_options
      end

      create_mailer("--repository=#{@remote_tracking_repository}",
                    "--name=sample-repo",
                    "--error-to=error@example.com",
                    DATE_OPTION,
                    "--track-remote",
                    "to@example", *options)
    end

    def get_mails_of_last_push
      push_mail, commit_mails = nil, []

      reference_changes = @mailer.fetch
      reference_changes.each do |old_revision, new_revision, reference|
        push_mail, commit_mails = process_reference_change(old_revision, new_revision, reference)
      end

      [push_mail, commit_mails]
    end

    def each_reference_change
      reference_changes = @mailer.fetch
      reference_changes.each do |old_revision, new_revision, reference|
        puts "#{old_revision} #{new_revision} #{reference}" if ENV['DEBUG']
        yield old_revision, new_revision, reference
      end
    end

    def assert_header(expected_header, actual_header)
      assert_equal(expected_header.gsub(/^X-Git-Refname: refs\/heads\/master$/,
                                        'X-Git-Refname: refs/remotes/origin/master'),
                   actual_header)
    end

    def assert_body(expected_body, actual_body)
      assert_equal(expected_body.gsub(/refs\/heads\/master/,
                                      'refs/remotes/origin/master'),
                   actual_body)
    end
  end

  class GitCommitMailerDiffTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerDiffTest
  end

  class GitCommitMailerFileManipulationTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerFileManipulationTest
  end

  class GitCommitMailerNoDiffTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerNoDiffTest

    def initialize(*args)
      super(*args)
      set_additional_default_mailer_option("--no-diff")
    end
  end

  class GitCommitMailerTagTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerTagTest
  end

  class GitCommitMailerMergeTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerMergeTest
  end

  class GitCommitMailerNonAsciiTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerNonAsciiTest
  end

  class GitCommitMailerOptionTest < Test::Unit::TestCase
    include Utils
    include ::GitCommitMailerOptionTest
  end
end
