# -*- coding: utf-8 -*-
#
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

require "fileutils"
require "webrick/httpstatus"
require "shellwords"
require "uri"

require "rubygems"
require "json"

class GitHubPostReceiver
  module PathResolver
    def base_dir
      @base_dir ||=
        @options[:base_dir] ||
        File.expand_path(File.join(File.dirname(__FILE__), ".."))
    end

    def path(*paths)
      File.expand_path(File.join(base_dir, *paths))
    end
  end

  include PathResolver

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
    repository = process_payload_repository(request, response, payload)
    return if repository.nil?
    before, after, reference =
      process_push_parameters(request, response, payload)
    repository.process(before, after, reference)
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

    repository_uri = repository["url"]
    domain = extract_domain(repository_uri)
    if domain.nil?
      set_error_response(response, :bad_request,
                         "invalid repository URI: <#{repository.inspect}>")
      return
    end

    repository_name = repository["name"]
    if repository_name.nil?
      set_error_response(response, :bad_request,
                         "repository name is missing: <#{repository.inspect}>")
      return
    end

    owner_name = extract_owner_name(repository_uri, payload)
    if owner_name.nil?
      set_error_response(response, :bad_request,
                         "repository owner or owner name is missing: " +
                         "<#{repository.inspect}>")
      return
    end

    unless target?(owner_name, repository_name)
      set_error_response(response, :forbidden,
                         "unacceptable repository: " +
                         "<#{owner_name.inspect}>:<#{repository_name.inspect}>")
      return
    end

    options = repository_options(domain, owner_name, repository_name)
    repository_class.new(domain, owner_name, repository_name, payload, options)
  end

  def extract_domain(repository_uri)
    domain = nil
    case repository_uri
    when /\Agit@/
      domain = repository_uri[/@(.+):/, 1]
    when /\Ahttps:\/\//
      domain = URI.parse(repository_uri).hostname
    else
      return
    end
    domain
  end

  def extract_owner_name(repository_uri, payload)
    owner_name = nil
    repository = payload["repository"]
    if gitlab_payload?(payload)
      case repository_uri
      when /\Agit@/
        owner_name = repository_uri[%r!git@.+:(.+)/.+(?:.git)?!, 1]
      when /\Ahttps:\/\//
        owner_name = URI.parse(repository_uri).path.sub(/\A\//, "")
      else
        return
      end
    else
      owner = repository["owner"]
      return if owner.nil?

      owner_name = owner["name"]
      return if owner_name.nil?
    end
    owner_name
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

    reference = payload["ref"]
    if reference.nil?
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

  def gitlab_payload?(payload)
    not payload["user_name"].nil?
  end

  def target?(owner_name, repository_name)
    (@options[:targets] || [/\A[a-z\d_.\-]+\z/i]).any? do |target|
      target === repository_name
    end
  end

  KEYWORD_TO_HTTP_STATUS_CODE = {}
  WEBrick::HTTPStatus::StatusMessage.each do |code, message|
    KEYWORD_TO_HTTP_STATUS_CODE[message.downcase.gsub(/ +/, "_").intern] = code
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

  def repository_options(domain, owner_name, repository_name)
    domain_options = (@options[:domains] || {})[domain] || {}
    domain_options = symbolize_options(domain_options)
    domain_owner_options = (domain_options[:owners] || {})[owner_name] || {}
    domain_owner_options = symbolize_options(domain_owner_options)
    domain_repository_options = (domain_owner_options[:repositories] || {})[repository_name] || {}
    domain_repository_options = symbolize_options(domain_repository_options)

    owner_options = (@options[:owners] || {})[owner_name] || {}
    owner_options = symbolize_options(owner_options)
    _repository_options = (owner_options[:repositories] || {})[repository_name] || {}
    _repository_options = symbolize_options(_repository_options)

    options = @options.merge(owner_options)
    options = options.merge(owner_options)
    options = options.merge(_repository_options)

    options = options.merge(domain_options)
    options = options.merge(domain_owner_options)
    options = options.merge(domain_repository_options)
    options
  end

  class Repository
    include PathResolver

    class Error < StandardError
    end

    def initialize(domain, owner_name, name, payload, options)
      @domain = domain
      @owner_name = owner_name
      @name = name
      @payload = payload
      @options = options
      @to = @options[:to]
      @max_n_retries = (@options[:n_retries] || 3).to_i
      raise Error.new("mail receive address is missing: <#{@name}>") if @to.nil?
    end

    def process(before, after, reference)
      FileUtils.mkdir_p(mirrors_directory)
      n_retries = 0
      begin
        if File.exist?(mirror_path)
          git("--git-dir", mirror_path, "fetch", "--quiet")
        else
          git("clone", "--quiet", "--mirror", repository_uri, mirror_path)
        end
      rescue Error
        n_retries += 1
        retry if n_retries <= @max_n_retries
        raise
      end
      send_commit_email(before, after, reference)
    end

    def send_commit_email(before, after, reference)
      options = [
        "--repository", mirror_path,
        "--max-size", "1M"
      ]
      if gitlab_payload?
        add_option(options, "--repository-browser", "gitlab")
        gitlab_project_uri = @payload["repository"]["homepage"]
        add_option(options, "--gitlab-project-uri", gitlab_project_uri)
      else
        add_option(options, "--repository-browser", "github")
        add_option(options, "--github-user", @owner_name)
        add_option(options, "--github-repository", @name)
        add_option(options, "--name", "#{@owner_name}/#{@name}")
      end
      add_option(options, "--from", from)
      add_option(options, "--from-domain", from_domain)
      add_option(options, "--sender", sender)
      add_option(options, "--sleep-per-mail", sleep_per_mail)
      options << "--send-per-to" if send_per_to?
      options << "--add-html" if add_html?
      error_to.each do |_error_to|
        options.concat(["--error-to", _error_to])
      end
      if @to.is_a?(Array)
        options.concat(@to)
      else
        options << @to
      end
      command_line = [ruby, commit_email, *options].collect do |component|
        Shellwords.escape(component)
      end.join(" ")
      change = "#{before} #{after} #{reference}"
      IO.popen(command_line, "w") do |io|
        io.puts(change)
      end
      unless $?.success?
        raise Error.new("failed to run commit-email.rb: " +
                        "<#{command_line}>:<#{change}>")
      end
    end

    private
    def git(*arguments)
      arguments = arguments.collect {|argument| argument.to_s}
      command_line = [git_command, *arguments]
      unless system(*command_line)
        raise Error.new("failed to run command: <#{command_line.join(' ')}>")
      end
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
      @mirror_path ||= File.join(mirrors_directory, @domain, @owner_name, @name)
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

    def from
      @from ||= @options[:from]
    end

    def from_domain
      @from_domain ||= @options[:from_domain]
    end

    def sender
      @sender ||= @options[:sender]
    end

    def sleep_per_mail
      @sleep_per_mail ||= @options[:sleep_per_mail]
    end

    def error_to
      @error_to ||= force_array(@options[:error_to])
    end

    def send_per_to?
      @options[:send_per_to]
    end

    def add_html?
      @options[:add_html]
    end

    def force_array(value)
      if value.is_a?(Array)
        value
      elsif value.nil?
        []
      else
        [value]
      end
    end

    def repository_uri
      if gitlab_payload?
        @payload['repository']['url']
      else
        "#{@payload['repository']['url']}.git"
      end
    end

    def add_option(options, name, value)
      return if value.nil?
      value = value.to_s
      return if value.empty?
      options.concat([name, value])
    end

    def gitlab_payload?
      not @payload["user_name"].nil?
    end
  end
end
