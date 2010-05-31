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
    assert_equal("payload parameter is missing", response_body)
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
    name = "evil-repository"
    post_payload(:repository => {
                   :name => name,
                 })
    assert_response("Forbidden")
    assert_equal("unacceptable repository: <#{name.inspect}>",
                 response_body)
  end

  def test_post_without_before
    payload = {
      "repository" => {
        "url" => "http://github.com/ranguba/rroonga",
        "name" => "rroonga",
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
        "url" => "http://github.com/ranguba/rroonga",
        "name" => "rroonga",
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
        "url" => "http://github.com/ranguba/rroonga",
        "name" => "rroonga",
      },
    }
    post_payload(payload)
    assert_response("Bad Request")
    assert_equal("reference is missing: <#{payload.inspect}>",
                 response_body)
  end

  def test_post
    assert_false(File.exist?(mirror_path("rroonga")))
    before = "0f2be32a3671360a323f1dee64c757bc9fc44998"
    after = "c7bf92799225d67788be7c42ea4f504a47708390"
    reference = "refs/heads/master"
    post_payload(:repository => {
                   :url => "http://github.com/ranguba/rroonga",
                   :name => "rroonga",
                 },
                 :before => before,
                 :after => after,
                 :ref => reference)
    assert_response("OK")
    assert_true(File.exist?(mirror_path("rroonga")))
    result = YAML.load_file(File.join(@tmp_dir, "commit-email-result.yaml"))
    assert_equal([{
                    "argv" => ["--repository", mirror_path("rroonga"),
                               "--from-domain", "example.com",
                               "--name", "rroonga",
                               "--max-size", "1M",
                               "null@example.com"],
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
