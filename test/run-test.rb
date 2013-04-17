#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
#
# Copyright (C) 2013  Kouhei Sutou <kou@clear-code.com>
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

system("git --version")

$VERBOSE = true

top_dir = File.expand_path(File.join(File.dirname(__FILE__), ".."))
test_dir = File.dirname(__FILE__)

require "rubygems"
require "test-unit"
require "test/unit/rr"
require "tempfile"
require "nkf"

$LOAD_PATH.unshift(top_dir)

require "commit-email"

ENV["TZ"] = "Asia/Tokyo"
ENV["TEST_UNIT_MAX_DIFF_TARGET_STRING_SIZE"] ||= "500000"

GitCommitMailer::Info.host_name = "git-utils.example.com"

exit Test::Unit::AutoRunner.run(true, test_dir)
