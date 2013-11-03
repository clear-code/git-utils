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
    def test_post
      gitlab_project_uri = "https://gitlab.example.com/ranguba/rroonga"
      repository_mirror_path = mirror_path("ranguba", "rroonga")
      assert_false(File.exist?(repository_mirror_path))
      before = "0f2be32a3671360a323f1dee64c757bc9fc44998"
      after = "c7bf92799225d67788be7c42ea4f504a47708390"
      reference = "refs/heads/master"
      post_payload(:repository => {
                     :homepage => gitlab_project_uri,
                     :url => "git@gitlab.example.com:ranguba/rroonga.git",
                     :name => "rroonga",
                   },
                   :before => before,
                   :after => after,
                   :ref => reference,
                   :user_name => "jojo")
      assert_response("OK")
      assert_true(File.exist?(repository_mirror_path), repository_mirror_path)
      result = YAML.load_file(File.join(@tmp_dir, "commit-email-result.yaml"))
      assert_equal([{
                       "argv" => [
                         "--repository", repository_mirror_path,
                         "--max-size", "1M",
                         "--repository-browser", "gitlab",
                         "--gitlab-project-uri", gitlab_project_uri,
                         "--sender", "sender@example.com",
                         "--error-to", "error@example.com",
                         "global-to@example.com"
                       ],
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
