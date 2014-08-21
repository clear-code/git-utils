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

require "open-uri"
require "json"

require "github-event-watcher/event"

module GitHubEventWatcher
  class Watcher
    def initialize(state, logger)
      @repositories = []
      @state = state
      @logger = logger
    end

    def add_repository(name)
      @logger.info("[watcher][repository] add: <#{name}>")
      @repositories << name
    end

    def watch
      i = 0
      loop do
        name = @repositories[i]
        events = fetch_events(name)
        processed_event_id = @state.processed_event_id(name)
        events = remove_processed_events(events, processed_event_id)
        @logger.info("[watcher][watch][#{name}] target events: <#{events.size}>")
        sorted_events = events.sort_by do |event|
          event.id
        end
        sorted_events.reverse_each do |event|
          yield(event)
        end
        latest_event = sorted_events.last
        if latest_event
          @logger.info("[watcher][watch][#{name}] last processed event ID: " +
                       "<#{latest_event.id}>")
          @state.update_processed_event_id(name, latest_event.id)
        end
        sleep(60)
        i = (i + 1) % @repositories.size
      end
    end

    private
    def fetch_events(name)
      open("https://api.github.com/repos/#{name}/events") do |body|
        JSON.parse(body.read).collect do |event|
          Event.new(event)
        end
      end
    end

    def remove_processed_events(events, processed_event_id)
      events.reject do |event|
        event.id <= processed_event_id
      end
    end
  end
end
