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
    @tmp_dir = File.join(File.dirname(__FILE__), "tmp")
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
  end

  def test_post_with_empty_payload
    visit "/", :post, :payload => ""
    assert_response("Bad Request")
  end

  def test_post_with_non_target_repository
    post_payload(:repository => {
                   :name => "evil-repository",
                 })
    assert_response("Forbidden")
  end

  def test_post
    omit("should not use real repository.")
    post_payload(:repository => {
                   :url => "http://github.com/ranguba/rroonga",
                   :name => "rroonga",
                 })
    assert_response("OK")
  end

  private
  def post_payload(payload)
    visit "/", :post, :payload => JSON.generate(payload)
  end

  def options
    @options ||= {
      :targets => ["rroonga"],
      :base_dir => @tmp_dir,
    }
  end
end
