# Copyright (C) 2013 Kenji Okimoto <okimoto@clear-code.com>
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

require "yaml"

class MultiSiteReceiverTest < Test::Unit::TestCase
  include GitHubPostReceiverTestUtils

  def setup
    test_dir = File.dirname(__FILE__)
    @fixtures_dir = File.join(test_dir, "fixtures")
    @tmp_dir = File.join(test_dir, "tmp")
    FileUtils.mkdir_p(@tmp_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmp_dir)
  end

  def app
    options = YAML.load_file(File.join(@fixtures_dir, "config-multi-site.yaml"))
    options[:base_dir] = @tmp_dir
    options[:fixtures_dir] = @fixtures_dir
    options[:commit_email] = File.join(@fixtures_dir, "mock-commit-email.rb")
    options[:git] = File.join(@fixtures_dir, "stub-git.rb")
    GitHubPostReceiver.new(options)
  end

  class GitLabTest < self
    data("gitlab.example.com/ranguba/rroonga" => {
           :params => {
             :domain => "gitlab.example.org",
             :owner_name => "ranguba",
             :repository_name => "rroonga"
           },
           :expected => {
             :sender => "sender@example.com",
             :error_to => "error@example.com",
             :to => "global-to@example.com",
           }
         },
         "gitlab.example.net/clear-code/git-utils" => {
           :params => {
             :domain => "gitlab.example.net",
             :owner_name => "clear-code",
             :repository_name => "git-utils"
           },
           :expected => {
             :add_html => true,
             :sender => "sender@example.com",
             :error_to => "error@example.com",
             :to => "commit@example.net",
           }
         },
         "gitlab.example.net/support/git-utils" => {
           :params => {
             :domain => "gitlab.example.net",
             :owner_name => "support",
             :repository_name => "git-utils"
           },
           :expected => {
             :add_html => false,
             :from => "support+null@example.net",
             :sender => "sender@example.com",
             :error_to => "error@example.com",
             :to => "support@example.net",
           }
         },
         "gitlab.example.org/clear-code/test-project1" => {
           :params => {
             :domain => "gitlab.example.org",
             :owner_name => "clear-code",
             :repository_name => "test-project1"
           },
           :expected => {
             :add_html => true,
             :from => "null@example.org",
             :sender => "sender@example.com",
             :error_to => "error@example.com",
             :to => "commit+test-project1@example.org",
           }
         },
         "gitlab.example.org/clear-code/test-project2" => {
           :params => {
             :domain => "gitlab.example.org",
             :owner_name => "clear-code",
             :repository_name => "test-project2"
           },
           :expected => {
             :add_html => false,
             :from => "null@example.org",
             :sender => "sender@example.com",
             :error_to => "error@example.com",
             :to => "commit+test-project2@example.org",
           }
         })
    def test_post(data)
      domain = data[:params][:domain]
      owner_name = data[:params][:owner_name]
      repository_name = data[:params][:repository_name]
      gitlab_project_uri = "https://#{domain}/#{owner_name}/#{repository_name}"
      repository_uri = "git@#{domain}:#{owner_name}/#{repository_name}.git"
      repository_mirror_path = mirror_path(owner_name, repository_name)
      add_html = data[:expected][:add_html]
      from = data[:expected][:from]
      sender = data[:expected][:sender]
      error_to = data[:expected][:error_to]
      to = data[:expected][:to]
      assert_false(File.exist?(repository_mirror_path))
      before = "0f2be32a3671360a323f1dee64c757bc9fc44998"
      after = "c7bf92799225d67788be7c42ea4f504a47708390"
      reference = "refs/heads/master"
      expected_argv = [
        "--repository", repository_mirror_path,
        "--max-size", "1M",
        "--repository-browser", "gitlab",
        "--gitlab-project-uri", gitlab_project_uri
      ]
      expected_argv.push("--from", from) if from
      expected_argv.push("--sender", sender)
      expected_argv.push("--add-html") if add_html
      expected_argv.push("--error-to", error_to)
      expected_argv.push(to)
      post_payload(:repository => {
                     :homepage => gitlab_project_uri,
                     :url => repository_uri,
                     :name => repository_name,
                   },
                   :before => before,
                   :after => after,
                   :ref => reference,
                   :user_name => "jojo")
      assert_response("OK")
      assert_true(File.exist?(repository_mirror_path), repository_mirror_path)
      result = YAML.load_file(File.join(@tmp_dir, "commit-email-result.yaml"))
      assert_equal([{
                       "argv" => expected_argv,
                       "lines" => ["#{before} #{after} #{reference}\n"],
                     }],
                   result)
    end
  end

  private

  def post_payload(payload)
    visit "/", :post, :payload => JSON.generate(payload)
  end

  def mirror_path(*components)
    File.join(@tmp_dir, "mirrors", *components)
  end
end
