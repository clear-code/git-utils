# -*- coding: utf-8 -*-
# Copyright (C) 2014  Kenji Okimoto <okimoto@clear-code.com>
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
require "gitlab-system-hooks-receiver"

class SystemHooksReceiverTest < Test::Unit::TestCase
  include GitHubPostReceiverTestUtils

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
    GitLabSystemHooksReceiver.new(options)
  end

  def test_get
    visit "/"
    assert_response("Method Not Allowed")
  end

  def test_post_without_parameters
    page.driver.post("/")
    assert_response("Bad Request")
    assert_equal("payload is missing", body)
  end

  def test_create_project
    mock(Capybara.app).add_project_hook(42, options[:hook_uri])
    payload = {
      created_at: "2014-03-13T07:30:54Z",
      event_name: "project_create",
      name: "ExampleProject",
      owner_email: "johnsmith@example.com",
      owner_name: "John Smith",
      path: "exampleproject",
      path_with_namespace: "jsmith/exampleproject",
      project_id: 42,
    }
    post_payload(payload)
    assert_response("OK")
  end

  private

  def post_payload(payload)
    page.driver.post("/", :payload => JSON.generate(payload))
  end

  def options
    @options ||= {
      :private_token => "VERYSECRETTOKEN",
      :gitlab_api_end_point_uri => "https://gitlab.example.com/api/v3",
      :hook_uri => "https://hook.example.com/post-receiver"
    }
  end
end

