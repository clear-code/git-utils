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
require 'net/smtp'

require 'rubygems'
require 'json'

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
    begin
      process(request, response)
    rescue Exception => exception
      raise unless production?
      begin
        notify_exception(exception, request)
      rescue Exception
        begin
          $stderr.puts("#{$!.class}: #{$!}")
          $stderr.puts($@)
        rescue Exception
        end
      end
      set_error_response(response, :internal_server_error,
                         "Internal Server Error")
    end
    response.to_a
  end

  private
  def production?
    ENV["RACK_ENV"] == "production"
  end

  def symbolize_options(options)
    symbolized_options = {}
    options.each do |key, value|
      value = symbolize_options(value) if value.is_a?(Hash)
      symbolized_options[key.to_sym] = value
    end
    symbolized_options
  end

  def notify_exception(exception, request)
    notifier = ExceptionMailNotifier.new(exception, request, @options)
    notifier.notify
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

    repository_name = repository["name"]
    if repository_name.nil?
      set_error_response(response, :bad_request,
                         "repository name is missing: <#{repository.inspect}>")
      return
    end

    owner = repository["owner"]
    if owner.nil?
      set_error_response(response, :bad_request,
                         "repository owner is missing: <#{repository.inspect}>")
      return
    end

    owner_name = owner["name"]
    if owner_name.nil?
      set_error_response(response, :bad_request,
                         "repository owner name is missing: " +
                         "<#{repository.inspect}>")
      return
    end

    unless target?(owner_name, repository_name)
      set_error_response(response, :forbidden,
                         "unacceptable repository: " +
                         "<#{owner_name.inspect}>:<#{repository_name.inspect}>")
      return
    end

    repository_class.new(owner_name, repository_name, payload,
                         repository_options(owner_name, repository_name))
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

  def target?(owner_name, repository_name)
    (@options[:targets] || [/\A[a-z\d_\-]+\z/i]).any? do |target|
      target === repository_name
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

  def repository_options(owner_name, repository_name)
    owner_options = (@options[:owners] || {})[owner_name] || {}
    _repository_options = owner_options[repository_name] || {}
    @options.merge(owner_options).merge(_repository_options)
  end

  class Repository
    include PathResolver

    class Error < StandardError
    end

    def initialize(owner_name, name, payload, options)
      @owner_name = owner_name
      @name = name
      @payload = payload
      @options = options
      @to = @options[:to]
      raise Error.new("mail receive address is missing: <#{@name}>") if @to.nil?
    end

    def process(before, after, reference)
      FileUtils.mkdir_p(mirrors_directory)
      if File.exist?(mirror_path)
        git("--git-dir", mirror_path, "fetch", "--quiet")
      else
        git("clone", "--quiet", "--mirror", repository_uri, mirror_path)
      end
      send_commit_email(before, after, reference)
    end

    def send_commit_email(before, after, reference)
      options = ["--repository", mirror_path,
                 "--name", "#{@owner_name}/#{@name}",
                 "--max-size", "1M"]
      options.concat(["--from-domain", from_domain]) if from_domain
      options.concat(["--sender", sender]) if sender
      options.concat(["--error-to", error_to]) if error_to
      options << @to
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
      @mirror_path ||= File.join(mirrors_directory, @owner_name, @name)
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
      @from_domain ||= @options[:from_domain]
    end

    def sender
      @sender ||= @options[:sender]
    end

    def error_to
      @error_to ||= @options[:error_to]
    end

    def repository_uri
      "#{@payload['repository']['url'].sub(/\Ahttp/, 'git')}.git"
    end
  end

  class ExceptionMailNotifier
    def initialize(exception, request, options={})
      @exception = exception
      @request = request
      @options = options
    end

    def notify
      return if to.empty?
      mail = format
      Net::SMTP.start(@options[:host] || "localhost") do |smtp|
        smtp.send_message(mail, from, *to)
      end
    end

    private
    def format
      mail = "#{format_header}\n#{format_body}"
      mail.force_encoding("UTF-8")
      begin
        mail = mail.encode('iso-2022-jp')
      rescue EncodingError
      end
      mail.force_encoding("ASCII-8BIT")
    end

    def format_header
      <<-EOH
Mime-Version: 1.0
Content-Type: Text/Plain; charset=iso-2022-jp
Content-Transfer-Encoding: 7bit
From: #{from}
To: #{to.join(', ')}
Subject: #{NKF.nkf('-Wj -M', subject)}
EOH
    end

    def format_body
      body = <<-EOB
URL: #{@request.url}
--
#{@exception.class}: #{@exception}
--
#{@exception.backtrace.join("\n")}
EOB
      params = @request.params
      max_key_size = (@request.env.keys.collect(&:size) +
                      params.keys.collect(&:size)).max
      body << <<-EOE
--
Environments:
EOE
      @request.env.sort_by {|key, value| key}.each do |key, value|
        body << "  %*s: <%s>\n" % [max_key_size, key, value]
      end

      unless params.empty?
        body << <<-EOE
--
Parameters:
EOE
        params.sort_by {|key, value| key}.each do |key, value|
          body << "  %#{max_key_size}s: <%s>\n" % [key, value]
        end
      end

      body
    end

    def subject
      "[git-utils] #{@exception}"
    end

    def to
      @to ||= ensure_array(@options[:error_to]) || []
    end

    def ensure_array(maybe_array)
      maybe_array = [maybe_array] if maybe_array.is_a?(String)
      maybe_array
    end

    def from
      @from ||= @options[:from] || guess_from
    end

    def guess_from
      name = Etc.getpwuid(Process.uid).name
      host = Socket.gethostname
      "#{name}@#{host}"
    end
  end
end
