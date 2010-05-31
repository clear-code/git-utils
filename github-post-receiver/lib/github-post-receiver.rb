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

require 'fileutils'
require 'webrick/httpstatus'
require 'shellwords'

require 'rubygems'
require 'json'

class GitHubPostReceiver
  module PathResolver
    def base_dir
      @base_dir ||= @options[:base_dir]
    end

    def path(*paths)
      File.expand_path(File.join(base_dir, *paths))
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

    payload = parse_payload(request, response)
    return if payload.nil?
    process_payload(request, response, payload)
  end

  def parse_payload(request, response)
    payload = request["payload"]
    if payload.nil?
      set_error_response(response, :bad_request, "payload parameter is missing")
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
    repository = process_payload_repository(request, response, payload)
    return if repository.nil?
    before, after, reference =
      process_push_parameters(request, response, payload)
    begin
      repository.process(before, after, reference)
    rescue Repository::Error
      set_error_response(response, :internal_server_error,
                         "failed to send commit mail: <#{$!.message}>")
    end
  end

  def process_payload_repository(request, response, payload)
    repository = payload["repository"]
    if repository.nil?
      set_error_response(response, :bad_request,
                         "repository information is missing: " +
                         "<#{payload.inspect}>")
      return
    end

    unless repository.is_a?(Hash)
      set_error_response(response, :bad_request,
                         "invalid repository information format: " +
                         "<#{repository.inspect}>")
      return
    end

    name = repository["name"]
    if name.nil?
      set_error_response(response, :bad_request,
                         "repository name is missing: " +
                         "<#{repository.inspect}>")
      return
    end

    unless target?(name)
      set_error_response(response, :forbidden,
                         "unacceptable repository: <#{name.inspect}>")
      return
    end

    repository_class.new(name, payload, @options)
  end

  def process_push_parameters(request, response, payload)
    before = payload["before"]
    if before.nil?
      set_error_response(response, :bad_request,
                         "before commit ID is missing: <#{payload.inspect}>")
      return
    end

    after = payload["after"]
    if after.nil?
      set_error_response(response, :bad_request,
                         "after commit ID is missing: <#{payload.inspect}>")
      return
    end

    reference = payload["reference"]
    if after.nil?
      set_error_response(response, :bad_request,
                         "reference is missing: <#{payload.inspect}>")
      return
    end

    [before, after, reference]
  end

  def set_error_response(response, status_keyword, message)
    response.status = status(status_keyword)
    response["Content-Type"] = "text/plain"
    response.write(message)
  end

  def target?(name)
    (@options[:targets] || [/\Aa-z\d_\-\z/i]).any? do |target|
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

  def repository_class
    @options[:repository_class] || Repository
  end

  class Repository
    include PathResolver

    class Error < StandardError
    end

    def initialize(name, payload, options)
      @name = name
      @payload = payload
      @options = options
      @to = @options[:to]
      raise Error.new("mail receive address is missing: <#{@name}>") if @to.nil?
    end

    def process(before, after, reference)
      FileUtils.mkdir_p(mirrors_directory)
      if File.exist?(mirror_path)
        git("pull", "--git-dir", mirror_path, "--rebase")
      else
        git("clone", "--quiet", "--mirror", repository_uri, mirror_path)
      end
      send_commit_email(before, after, reference)
    end

    def send_commit_email(before, after, reference)
      options = ["--from-domain", from_domain,
                 "--name", @name,
                 "--max-size", "1M"]
      options.concat("--error-to", error_to) if error_to
      options << @to
      command_line = [ruby, commit_email, *options].collect do |component|
        Shellwords.escape(component)
      end.join(" ")
      IO.popen(command_line, "w") do |io|
        io.puts("#{before} #{after} #{reference}")
      end
    end

    private
    def git(*arguments)
      system(git_command, *(arguments.collect {|argument| argument.to_s}))
    end

    def git_command
      @git ||= @options[:git] || "git"
    end

    def mirrors_directory
      @mirrors_directory ||=
        @options[:mirrors_directory] ||
        path("mirrors")
    end

    def mirror_path
      @mirror_path ||= File.join(mirrors_directory, @name)
    end

    def ruby
      @ruby ||= @options[:ruby] || current_ruby
    end

    def current_ruby
      File.join(Config::CONFIG["bindir"], Config::CONFIG["RUBY_INSTALL_NAME"])
    end

    def commit_email
      @commit_email ||=
        @options[:commit_email] ||
        path("..", "commit-email.rb")
    end

    def from_domain
      @from_domain ||= @options[:from_domain] || "example.com"
    end

    def error_to
      @error_to ||= @options[:error_to]
    end

    def repository_uri
      "#{@payload['repository']['url'].sub(/\Ahttp/, 'git')}.git"
    end
  end
end
