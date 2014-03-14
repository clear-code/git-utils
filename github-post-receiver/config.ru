# -*- mode: ruby; coding: utf-8 -*-
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

require "yaml"

require "pathname"

base_dir = Pathname(__FILE__).dirname
lib_dir = base_dir + "lib"

racknga_base_dir = base_dir.parent.parent + "racknga"
racknga_lib_dir = racknga_base_dir + "lib"

$LOAD_PATH.unshift(racknga_lib_dir.to_s)
$LOAD_PATH.unshift(lib_dir.to_s)

require "github-post-receiver"

require "racknga/middleware/exception_notifier"

use Rack::CommonLogger
use Rack::Runtime
use Rack::ContentLength

config_file = base_dir + "config.yaml"
options = YAML.load_file(config_file.to_s)
notifier_options = options.dup
if options[:error_to]
  notifier_options[:to] = options[:error_to]
end
notifier_options.merge!(options["exception_notifier"] || {})
notifiers = [Racknga::ExceptionMailNotifier.new(notifier_options)]
use Racknga::Middleware::ExceptionNotifier, :notifiers => notifiers

map "/post-receiver/" do
  run GitHubPostReceiver.new(options)
end

