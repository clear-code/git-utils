#!/usr/bin/env ruby
#
# Copyright (C) 2010-2013  Kouhei Sutou <kou@clear-code.com>
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

base_dir = File.expand_path(File.join(File.dirname(__FILE__), ".."))
lib_dir = File.join(base_dir, "lib")
test_dir = File.join(base_dir, "test")

require "test-unit"
require "test/unit/capybara"
require "test/unit/rr"

ARGV.unshift("--priority-mode")

$LOAD_PATH.unshift(lib_dir)

$LOAD_PATH.unshift(test_dir)
require "github-post-receiver-test-utils"

exit Test::Unit::AutoRunner.run(true, test_dir)
