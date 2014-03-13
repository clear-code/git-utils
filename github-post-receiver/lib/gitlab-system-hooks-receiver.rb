# -*- coding: utf-8 -*-
#
# Copyright (C) 2014  Kenji Okimoto <okimoto@clear-code.com>
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
require "net/https"
require "webrick/httpstatus"
require "json"

require "web-hook-receiver-base"

class GitLabSystemHooksReceiver < WebHookReceiverBase

  private

  def process_payload(request, response, payload)
    event_name = payload["event_name"]
    __send__("process_#{event_name}_event", request, response, payload)
  end

  def process_project_create_event(request, response, payload)
    owner_email = payload["owner_email"]
    project_id = payload["project_id"]
    hook_uri = @options[:hook_uri]
    add_project_hook(project_id, hook_uri)
  end

  def method_missing(name, *args)
    if name =~ /\Aprocess_.*_event\z/
      puts name
    else
      super
    end
  end

  #
  # POST #{GitLabURI}/projects/:id/hooks
  #
  def add_project_hook(project_id, hook_uri)
    gitlab_api_end_point_uri = URI.parse(@options[:gitlab_api_end_point])
    path = File.join(gitlab_api_end_point_uri.path, "projects", project_id.to_s, "hooks")
    post_request = Net::HTTP::Post.new(path)
    # push_events is enabled by default
    post_request.set_form_data("url" => hook_uri,
                               "private_token" => @options[:private_token])
    http = Net::HTTP.new(gitlab_api_end_point_uri.host, gitlab_api_end_point_uri.port)
    if gitlab_api_end_point_uri.scheme == "https"
      http.use_ssl = true
      http.ca_path = "/etc/ssl/certs"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_depth = 5
    end
    response = nil
    http.start do
      response = http.request(post_request)
    end

    response
  end
end
