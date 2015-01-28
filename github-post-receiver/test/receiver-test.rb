# Copyright (C) 2010-2014  Kouhei Sutou <kou@clear-code.com>
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

class ReceiverTest < Test::Unit::TestCase
  include GitHubPostReceiverTestUtils

  class << self
    def startup
      test_dir = File.dirname(__FILE__)
      fixtures_dir = File.join(test_dir, "fixtures")
      @rroonga_git_dir = File.join(fixtures_dir, "rroonga.git")
      system("git", "clone", "--mirror", "-q",
             "https://github.com/ranguba/rroonga.git", @rroonga_git_dir)
    end

    def shutdown
      FileUtils.rm_rf(@rroonga_git_dir)
    end
  end

  def setup
    test_dir = File.dirname(__FILE__)
    @fixtures_dir = File.join(test_dir, "fixtures")
    @tmp_dir = File.join(test_dir, "tmp")
    FileUtils.mkdir_p(@tmp_dir)
    Capybara.app = app
  end

  def teardown
    FileUtils.rm_rf(@tmp_dir)
  end

  def app
    GitHubPostReceiver.new(options)
  end

  def test_get
    visit "/"
    assert_response("Method Not Allowed")
  end

  def test_post_ping
    payload = {
      "zen" => "Speak like a human.",
      "hook_id" => 2043443,
    }
    env = {
      "HTTP_X_GITHUB_EVENT" => "ping",
    }
    post_payload(payload, env)
    assert_response("OK")
    assert_equal("", body)
  end

  def test_post_without_parameters
    page.driver.post("/")
    assert_response("Bad Request")
    assert_equal("payload is missing", body)
  end

  def test_post_with_empty_payload
    page.driver.post("/", :payload => "")
    assert_response("Bad Request")
    error_message = nil
    begin
      JSON.parse("")
    rescue
      error_message = $!.message
    end
    assert_equal("invalid JSON format: <#{error_message}>",
                 body)
  end

  class GitHubTest < self
    class << self
      def startup
      end

      def shutdown
      end
    end

    def test_post_with_non_target_repository
      owner_name = "devil"
      repository_name = "evil-repository"
      post_payload(:repository => {
                     :name => repository_name,
                     :url => "https://github.com/super-devil/evil-repository",
                     :owner => {
                       :name => owner_name,
                     },
                   })
      assert_response("Forbidden")
      assert_equal("unacceptable repository: " +
                   "<#{owner_name.inspect}>:<#{repository_name.inspect}>",
                   body)
    end

    def test_post_without_owner
      repository = {
        "url" => "https://github.com/ranguba/rroonga",
        "name" => "rroonga",
      }
      payload = {
        "repository" => repository,
      }
      post_payload(payload)
      assert_response("Bad Request")
      assert_equal("repository owner or owner name is missing: <#{repository.inspect}>",
                   body)
    end

    def test_post_without_owner_name
      repository = {
        "url" => "https://github.com/ranguba/rroonga",
        "name" => "rroonga",
        "owner" => {},
      }
      payload = {
        "repository" => repository,
      }
      post_payload(payload)
      assert_response("Bad Request")
      assert_equal("repository owner or owner name is missing: <#{repository.inspect}>",
                   body)
    end

    def test_post_without_before
      payload = {
        "repository" => {
          "url" => "https://github.com/ranguba/rroonga",
          "name" => "rroonga",
          "owner" => {
            "name" => "ranguba",
          },
        }
      }
      post_payload(payload)
      assert_response("Bad Request")
      assert_equal("before commit ID is missing",
                   body)
    end

    def test_post_without_after
      payload = {
        "before" => "0f2be32a3671360a323f1dee64c757bc9fc44998",
        "repository" => {
          "url" => "https://github.com/ranguba/rroonga",
          "name" => "rroonga",
          "owner" => {
            "name" => "ranguba",
          },
        },
      }
      post_payload(payload)
      assert_response("Bad Request")
      assert_equal("after commit ID is missing",
                   body)
    end

    def test_post_without_reference
      payload = {
        "before" => "0f2be32a3671360a323f1dee64c757bc9fc44998",
        "after" => "c7bf92799225d67788be7c42ea4f504a47708390",
        "repository" => {
          "url" => "https://github.com/ranguba/rroonga",
          "name" => "rroonga",
          "owner" => {
            "name" => "ranguba",
          },
        },
      }
      post_payload(payload)
      assert_response("Bad Request")
      assert_equal("reference is missing",
                   body)
    end

    def test_post
      repository_mirror_path = mirror_path("github.com", "ranguba", "rroonga")
      assert_false(File.exist?(repository_mirror_path))
      before = "0f2be32a3671360a323f1dee64c757bc9fc44998"
      after = "c7bf92799225d67788be7c42ea4f504a47708390"
      reference = "refs/heads/master"
      post_payload(:repository => {
                     :url => "https://github.com/ranguba/rroonga",
                     :name => "rroonga",
                     :owner => {
                       :name => "ranguba",
                     },
                   },
                   :before => before,
                   :after => after,
                   :ref => reference)
      assert_response("OK")
      assert_true(File.exist?(repository_mirror_path))
      result = YAML.load_file(File.join(@tmp_dir, "commit-email-result.yaml"))
      assert_equal([{
                       "argv" => ["--repository", repository_mirror_path,
                         "--max-size", "1M",
                         "--repository-browser", "github",
                         "--github-user", "ranguba",
                         "--github-repository", "rroonga",
                         "--name", "ranguba/rroonga",
                         "null@example.com"],
                       "lines" => ["#{before} #{after} #{reference}\n"],
                     }],
                   result)
    end

    def test_per_owner_configuration
      repository_mirror_path = mirror_path("github.com", "ranguba", "rroonga")
      assert_false(File.exist?(repository_mirror_path))
      options[:owners] = {
        "ranguba" => {
          :to => "ranguba-commit@example.org",
          :from => "ranguba+commit@example.org",
          :sender => "null@example.org",
        }
      }
      Capybara.app = app # TODO: extract option change tess to a sub test case
      before = "0f2be32a3671360a323f1dee64c757bc9fc44998"
      after = "c7bf92799225d67788be7c42ea4f504a47708390"
      reference = "refs/heads/master"
      post_payload(:repository => {
                     :url => "https://github.com/ranguba/rroonga",
                     :name => "rroonga",
                     :owner => {
                       :name => "ranguba",
                     },
                   },
                   :before => before,
                   :after => after,
                   :ref => reference)
      assert_response("OK")
      assert_true(File.exist?(repository_mirror_path))
      result = YAML.load_file(File.join(@tmp_dir, "commit-email-result.yaml"))
      assert_equal([{
                       "argv" => ["--repository", repository_mirror_path,
                         "--max-size", "1M",
                         "--repository-browser", "github",
                         "--github-user", "ranguba",
                         "--github-repository", "rroonga",
                         "--name", "ranguba/rroonga",
                         "--from", "ranguba+commit@example.org",
                         "--sender", "null@example.org",
                         "ranguba-commit@example.org"],
                       "lines" => ["#{before} #{after} #{reference}\n"],
                     }],
                   result)
    end

    def test_per_repository_configuration
      repository_mirror_path = mirror_path("github.com", "ranguba", "rroonga")
      assert_false(File.exist?(repository_mirror_path))
      options[:owners] = {
        "ranguba" => {
          :to => "ranguba-commit@example.org",
          :from => "ranguba+commit@example.org",
          :sender => "null@example.org",
          "repositories" => {
            "rroonga" => {
              :to => "ranguba-commit@example.net",
              :from => "ranguba+commit@example.net",
              :sender => "null@example.net",
            }
          }
        }
      }
      Capybara.app = app # TODO: extract option change tess to a sub test case
      before = "0f2be32a3671360a323f1dee64c757bc9fc44998"
      after = "c7bf92799225d67788be7c42ea4f504a47708390"
      reference = "refs/heads/master"
      post_payload(:repository => {
                     :url => "https://github.com/ranguba/rroonga",
                     :name => "rroonga",
                     :owner => {
                       :name => "ranguba",
                     },
                   },
                   :before => before,
                   :after => after,
                   :ref => reference)
      assert_response("OK")
      assert_true(File.exist?(repository_mirror_path))
      result = YAML.load_file(File.join(@tmp_dir, "commit-email-result.yaml"))
      assert_equal([{
                       "argv" => ["--repository", repository_mirror_path,
                         "--max-size", "1M",
                         "--repository-browser", "github",
                         "--github-user", "ranguba",
                         "--github-repository", "rroonga",
                         "--name", "ranguba/rroonga",
                         "--from", "ranguba+commit@example.net",
                         "--sender", "null@example.net",
                         "ranguba-commit@example.net"],
                       "lines" => ["#{before} #{after} #{reference}\n"],
                     }],
                   result)
    end

    def test_gollum
      repository_mirror_path =
        mirror_path("github.com", "ranguba", "rroonga.wiki")
      assert_false(File.exist?(repository_mirror_path))
      before = "83841cd1576e28d85aa5ec312fd3804d1352e5ab^"
      after = "83841cd1576e28d85aa5ec312fd3804d1352e5ab"
      reference = "refs/heads/master"
      payload = {
        "repository" => {
          "url" => "https://github.com/ranguba/rroonga",
          "clone_url" => "https://github.com/ranguba/rroonga.git",
          "name" => "rroonga",
          "owner" => {
            "login" => "ranguba",
          },
        },
        "pages" => [
          {
            "sha" => "83841cd1576e28d85aa5ec312fd3804d1352e5ab",
          },
        ],
      }
      env = {
        "HTTP_X_GITHUB_EVENT" => "gollum",
      }
      post_payload(payload, env)
      assert_response("OK")
      assert_true(File.exist?(repository_mirror_path))
      result = YAML.load_file(File.join(@tmp_dir, "commit-email-result.yaml"))
      assert_equal([
                     {
                       "argv" => [
                         "--repository", repository_mirror_path,
                         "--max-size", "1M",
                         "--repository-browser", "github-wiki",
                         "--github-user", "ranguba",
                         "--github-repository", "rroonga",
                         "--name", "ranguba/rroonga.wiki",
                         "null@example.com"],
                       "lines" => ["#{before} #{after} #{reference}\n"],
                     },
                   ],
                   result)
    end
  end

  private
  def post_payload(payload, env={})
    env = default_env.merge(env)
    page.driver.post("/", {:payload => JSON.generate(payload)}, env)
  end

  def default_env
    {
      "HTTP_X_GITHUB_EVENT" => "push",
    }
  end

  def options
    @options ||= {
      :targets => ["rroonga"],
      :base_dir => @tmp_dir,
      :fixtures_dir => @fixtures_dir,
      :repository_class => LocalRepository,
      :commit_email => File.join(@fixtures_dir, "mock-commit-email.rb"),
      :to => "null@example.com",
    }
  end

  def mirror_path(*components)
    File.join(@tmp_dir, "mirrors", *components)
  end
end
