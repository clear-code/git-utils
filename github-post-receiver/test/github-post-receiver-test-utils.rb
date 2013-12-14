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

require "github-post-receiver"

require "webrick/httpstatus"

module GitHubPostReceiverTestUtils
  include Capybara::DSL

  private
  def assert_response(code)
    assert_equal(resolve_status(code), resolve_status(status_code))
  end

  def resolve_status(code_or_message)
    messages = WEBrick::HTTPStatus::StatusMessage
    if code_or_message.is_a?(String)
      message = code_or_message
      [(messages.find {|key, value| value == message} || [])[0],
       message]
    else
      code = code_or_message
      [code, messages[code]]
    end
  end

  class LocalRepository < GitHubPostReceiver::Repository
    private
    def fixtures_dir
      @options[:fixtures_dir]
    end

    def repository_uri
      File.join(fixtures_dir, "#{@name}.git")
    end
  end
end
