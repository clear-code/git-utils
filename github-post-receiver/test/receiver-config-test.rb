# -*- coding: utf-8 -*-
#
# Copyright (C) 2013  Kenji Okimoto <okimoto@clear-code.com>
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

require "test-unit"

require "github-post-receiver"

class ReceiverConfigTest < Test::Unit::TestCase
  def setup
    fixtures_dir = File.expand_path(File.join(File.dirname(__FILE__), "fixtures"))
    options = YAML.load_file(File.join(fixtures_dir, "config-multi-site.yaml"))
    @receiver = GitHubPostReceiver.new(options)
  end

  def test_repository_options
    options = @receiver.__send__(:repository_options, "github.com", "clear-code", "git-utils")
    assert_equal("commit@clear-code.com", options[:to])
    assert_equal(true, options[:add_html])
  end

end
