# Copyright (C) 2010  Kouhei Sutou <kou@clear-code.com>
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
    GitHubPostReceiver.new(options)
  end

  def test_get
    visit "/"
    assert_response("Method Not Allowed")
  end

  def test_post_without_parameters
    visit "/", :post
    assert_response("Bad Request")
    assert_equal("payload is missing", response_body)
  end

  def test_post_with_empty_payload
    visit "/", :post, :payload => ""
    assert_response("Bad Request")
    error_message = nil
    begin
      JSON.parse("")
    rescue
      error_message = $!.message
    end
    assert_equal("invalid JSON format: <#{error_message}>",
                 response_body)
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
                 response_body)
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
    assert_equal("repository owner is missing: <#{repository.inspect}>",
                 response_body)
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
    assert_equal("repository owner name is missing: <#{repository.inspect}>",
                 response_body)
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
    assert_equal("before commit ID is missing: <#{payload.inspect}>",
                 response_body)
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
    assert_equal("after commit ID is missing: <#{payload.inspect}>",
                 response_body)
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
    assert_equal("reference is missing: <#{payload.inspect}>",
                 response_body)
  end

  def test_post
    repository_mirror_path = mirror_path("ranguba", "rroonga")
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
                               "--name", "ranguba/rroonga",
                               "--max-size", "1M",
                               "null@example.com"],
                    "lines" => ["#{before} #{after} #{reference}\n"],
                  }],
                 result)
  end

  def test_per_owner_configuration
    repository_mirror_path = mirror_path("ranguba", "rroonga")
    assert_false(File.exist?(repository_mirror_path))
    options[:owners] = {
      "ranguba" => {
        :to => "ranguba-commit@example.org",
        :from => "ranguba+commit@example.org",
        :sender => "null@example.org",
      }
    }
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
                               "--name", "ranguba/rroonga",
                               "--max-size", "1M",
                               "--from", "ranguba+commit@example.org",
                               "--sender", "null@example.org",
                               "ranguba-commit@example.org"],
                    "lines" => ["#{before} #{after} #{reference}\n"],
                  }],
                 result)
  end

  def test_per_repository_configuration
    repository_mirror_path = mirror_path("ranguba", "rroonga")
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
                               "--name", "ranguba/rroonga",
                               "--max-size", "1M",
                               "--from", "ranguba+commit@example.net",
                               "--sender", "null@example.net",
                               "ranguba-commit@example.net"],
                    "lines" => ["#{before} #{after} #{reference}\n"],
                  }],
                 result)
  end

  private
  def post_payload(payload)
    visit "/", :post, :payload => JSON.generate(payload)
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
