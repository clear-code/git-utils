# -*- mode: ruby; coding: utf-8 -*-
#
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

require 'yaml'

base_dir = ::File.dirname(__FILE__)
lib_dir = ::File.join(base_dir, "lib")
$LOAD_PATH.unshift(lib_dir)

require 'github-post-receiver'

use Rack::CommonLogger

map "/post-receiver/" do
  config_file = ::File.join(base_dir, "config.yaml")
  run GitHubPostReceiver.new(YAML.load_file(config_file))
end
