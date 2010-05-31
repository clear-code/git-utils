#!/usr/bin/env ruby

require 'yaml'

tmp_dir = File.join(File.dirname(__FILE__), "..", "tmp")
result_path = File.join(tmp_dir, "commit-email-result.yaml")

if File.exist?(result_path)
  result = YAML.load_file(result_path)
else
  result = []
end

lines = []
$stdin.each_line do |line|
  lines << line
end
result << {"argv" => ARGV, "lines" => lines}

File.open(result_path, "w") do |_result|
  _result.print(result.to_yaml)
end
