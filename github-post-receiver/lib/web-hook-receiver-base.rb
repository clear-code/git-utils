# -*- coding: utf-8 -*-
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

class WebHookReceiverBase
  def initialize(options={})
    @options = symbolize_options(options)
  end

  def call(env)
    request = Rack::Request.new(env)
    response = Rack::Response.new
    process(request, response)
    response.to_a
  end

  private

  def production?
    ENV["RACK_ENV"] == "production"
  end

  def symbolize_options(options)
    symbolized_options = {}
    options.each do |key, value|
      symbolized_options[key.to_sym] = value
    end
    symbolized_options
  end

  KEYWORD_TO_HTTP_STATUS_CODE = {}
  WEBrick::HTTPStatus::StatusMessage.each do |code, message|
    KEYWORD_TO_HTTP_STATUS_CODE[message.downcase.gsub(/ +/, '_').intern] = code
  end

  def status(keyword)
    code = KEYWORD_TO_HTTP_STATUS_CODE[keyword]
    if code.nil?
      raise ArgumentError, "invalid status keyword: #{keyword.inspect}"
    end
    code
  end

  def set_error_response(response, status_keyword, message)
    response.status = status(status_keyword)
    response["Content-Type"] = "text/plain"
    response.write(message)
  end

  def process(request, response)
    unless request.post?
      set_error_response(response, :method_not_allowed, "must POST")
      return
    end

    payload = parse_payload(request, response)
    return if payload.nil?
    process_payload(request, response, payload)
  end

  def parse_payload(request, response)
    if request.content_type == "application/json"
      payload = request.body.read
    else
      payload = request["payload"]
    end
    if payload.nil?
      set_error_response(response, :bad_request, "payload is missing")
      return
    end

    begin
      JSON.parse(payload)
    rescue JSON::ParserError
      set_error_response(response, :bad_request,
                         "invalid JSON format: <#{$!.message}>")
      nil
    end
  end

  def process_payload(request, response, payload)
    raise NotImplementedError, "Define this method in subclass"
  end
end
