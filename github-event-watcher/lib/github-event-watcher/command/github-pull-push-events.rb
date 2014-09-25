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

require "optparse"
require "fileutils"
require "pathname"
require "time"
require "logger"
require "yaml"

require "github-event-watcher"

module GitHubEventWatcher
  module Command
    class GitHubPullPushEvents
      def initialize
        @state_dir = Pathname.new("var/lib")
        @log_dir = Pathname.new("var/log")
        @config_file = Pathname.new("config.yaml")
        @pid_file = Pathname.new("var/run/github-pull-push-events.pid")
        @daemonize = false
      end

      def run(argv=ARGV)
        parse_command_line!(argv)
        expand_paths
        start_watcher
        true
      end

      private
      def parse_command_line!(argv)
        parser = OptionParser.new
        parser.version = VERSION
        parser.on("--state-dir=DIR",
                  "The directory to store state file",
                  "(#{@state_dir})") do |dir|
          @state_dir = Pathname.new(dir)
        end
        parser.on("--log-dir=DIR",
                  "The directory to store logs",
                  "(#{@log_dir})") do |dir|
          @log_dir = Pathname.new(dir)
        end
        parser.on("--config-file=FILE",
                  "The config file in YAML",
                  "(#{@config_file})") do |file|
          @config_file = Pathname.new(file)
        end
        parser.on("--pid-file=FILE",
                  "The PID file",
                  "(#{@pid_file})") do |file|
          @pid_file = Pathname.new(file)
        end
        parser.on("--[no-]daemonize",
                  "Run as a daemon",
                  "(#{@daemonize})") do |boolean|
          @daemonize = boolean
        end
        parser.parse!(argv)
      end

      def expand_paths
        @state_dir   = @state_dir.expand_path
        @log_dir     = @log_dir.expand_path
        @config_file = @config_file.expand_path
        @pid_file    = @pid_file.expand_path
      end

      def start_watcher
        state = create_state
        logger = create_logger
        watcher = Watcher.new(state, logger)
        config = load_config
        config["repositories"].each do |repository|
          watcher.add_repository(repository)
        end
        webhook_end_point = URI.parse(config["webhook-end-point"])
        webhook_sender = WebhookSender.new(webhook_end_point, logger)

        setup_signals(watcher)

        if @daemonize
          Process.daemon
          $stdout = create_io_logger("stdout")
          $stderr = create_io_logger("stderr")
          at_exit do
            $stdout.flush
            $stderr.flush
          end
        end
        create_pid_file

        begin
          watcher.watch do |event|
            next if event.type != "PushEvent"
            webhook_sender.send_push_event(event)
          end
        ensure
          remove_pid_file
        end

        logger.close
      end

      def create_state
        FileUtils.mkdir_p(@state_dir.to_s)
        PersistentState.new(@state_dir + "state.yaml")
      end

      def create_logger(type=nil)
        FileUtils.mkdir_p(@log_dir.to_s)
        components = ["github-pull-push-events", type, "log"].compact
        log_file = @log_dir + components.join(".")
        logger = Logger.new(log_file.to_s, 10, 1024 ** 2)
        logger.level = Logger::INFO
        logger.formatter = lambda do |severity, timestamp, program_name, message|
          "#{timestamp.iso8601}[#{severity.downcase}] #{message}\n"
        end
        logger
      end

      def create_io_logger(type)
        logger = create_logger(type)
        logger.level = Logger::DEBUG
        class << logger
          def write(message)
            message = message.strip
            return if message.empty?
            debug(message)
          end
        end
        logger
      end

      def load_config
        YAML.load(@config_file.read)
      end

      def setup_signals(watcher)
        trap(:INT) do
          watcher.stop
        end
        trap(:TERM) do
          watcher.stop
        end
      end

      def create_pid_file
        FileUtils.mkdir_p(@pid_file.dirname.to_s)
        @pid_file.open("w") do |pid_file|
          pid_file.print(Process.pid)
        end
      end

      def remove_pid_file
        return unless @pid_file.exist?
        FileUtils.rm_f(@pid_file.to_s)
      end
    end
  end
end
