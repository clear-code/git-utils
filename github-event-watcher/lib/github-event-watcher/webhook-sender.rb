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

require "net/http"
require "json"

module GitHubEventWatcher
  class WebhookSender
    def initialize(end_point, logger)
      @end_point = end_point
      @logger = logger
      @logger.info("[webhook-sender][end-point] <#{@end_point}>")
    end

    def send_push_event(event)
      @logger.info("[webhook-sender][send][push] " +
                   "<#{event.id}>:<#{event.repository_full_name}>")
      options = {
        :use_ssl => (@end_point.scheme == "https"),
      }
      begin
        Net::HTTP.start(@end_point.host, @end_point.port, options) do |http|
          request = Net::HTTP::Post.new(@end_point.request_uri)
          request["Host"] = @end_point.hostname
          request["X-GitHub-Event"] = "push"
          request["Content-Type"] = "application/json"
          request["User-Agent"] = "GitHub Event Watcher/1.0"
          request.body = JSON.generate(convert_to_push_event_payload(event))
          response = http.request(request)
          case response
          when Net::HTTPSuccess
            @logger.info("[webhook-sender][sent][push][success]")
          else
            @logger.error("[webhook-sender][sent][push][error] <#{response.code}>")
          end
        end
      rescue SystemCallError, Timeout::Error
        tag = "[webhook-sender][send][push][error]"
        message = "#{tag} Failed to send push event: #{$!.class}: #{$!.message}"
        @logger.error(message)
      end
    end

    private
    def convert_to_push_event_payload(event)
      {
        "ref"    => event.payload["ref"],
        "before" => event.payload["before"],
        "after"  => event.payload["head"],
        "repository" => {
          "url"       => event.repository_url,
          "name"      => event.repository_name,
          "full_name" => event.repository_full_name,
          "owner" => {
            "name" => event.repository_owner,
          },
        },
      }
    end
  end
end
