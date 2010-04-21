# -*- coding: utf-8 -*-
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

require 'webrick/httpstatus'

require 'rubygems'
require 'json'

class GitHubPostReceiver
  module PathResolver
    def base_dir
      @base_dir ||= @options[:base_dir]
    end

    def path(*paths)
      File.expand(File.join(base_dir, *paths))
    end
  end

  include PathResolver

  def initialize(options={})
    @options = options
  end

  def call(env)
    request = Rack::Request.new(env)
    response = Rack::Response.new
    process(request, response)
    response.to_a
  end

  private
  def process(request, response)
    unless request.post?
      set_error_response(response, :method_not_allowed, "must POST")
      return
    end

    payload = request["payload"]
    if payload.nil?
      set_error_response(response, :bad_request, "payload parameter is missing")
      return
    end

    begin
      payload = JSON.parse(payload)
    rescue JSON::ParserError
      set_error_response(response, :bad_request,
                         "invalid JSON format: <#{$!.message}>")
      return
    end
  end

  def set_error_response(response, status_keyword, message)
    response.status = status(status_keyword)
    response["Content-Type"] = "text/plain"
    response.write(message)
  end

  def target?(name)
    @options[:targets].any? do |target|
      target === name
    end
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

  class Repository
    include PathResolver

    def initialize(name, options)
      @name = name
      @options = options
    end

    def git
      @git ||= @options[:git] || "git"
    end

    def mirrors_directory
      @mirrors_directory ||=
        @options[:mirrors_directory] ||
        path("mirrors")
    end

    def mirror_path(name)
      path("mirrors", name)
    end

    def commit_email
      @commit_email ||=
        @options[:commit_email] ||
        path("..", "commit-email.rb")
    end
  end
end
