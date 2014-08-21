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

require "yaml"

module GitHubEventWatcher
  class PersistentState
    def initialize(path)
      @path = path
      load
    end

    def processed_event_id(repository_name)
      repository(repository_name)["processed-event-id"] || 0
    end

    def update_processed_event_id(repository_name, id)
      repository(repository_name)["processed-event-id"] = id
      save
    end

    private
    def repository(name)
      @repositories[name] ||= {}
    end

    def load
      if @path.exist?
        @repositories = YAML.load(@path.read)
      else
        @repositories = {}
      end
    end

    def save
      @path.open("w") do |file|
        file.print(@repositories.to_yaml)
      end
    end
  end
end
