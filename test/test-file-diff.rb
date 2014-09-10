# -*- coding: utf-8 -*-
#
# Copyright (C) 2014  Kouhei Sutou <kou@clear-code.com>
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

class FileDiffTest < Test::Unit::TestCase
  sub_test_case("parse_header") do
    def parse_header(header_line)
      lines = [header_line]
      file_diff = GitCommitMailer::CommitInfo::FileDiff.allocate
      file_diff.send(:parse_header, lines)
      [
        file_diff.instance_variable_get(:@from_file),
        file_diff.instance_variable_get(:@to_file),
      ]
    end

    def test_no_space
      assert_equal([
                     "hello.txt",
                     "hello.txt",
                   ],
                   parse_header("diff --git a/hello.txt b/hello.txt"))
    end

    def test_have_space
      assert_equal([
                     "hello world.txt",
                     "hello world.txt",
                   ],
                   parse_header("diff --git a/hello world.txt b/hello world.txt"))
    end
  end
end
