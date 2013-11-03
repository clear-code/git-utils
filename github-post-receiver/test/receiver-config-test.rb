# -*- coding: utf-8 -*-
#
# Copyright (C) 2013  Kenji Okimoto <okimoto@clear-code.com>
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

require "test-unit"
require "yaml"

require "github-post-receiver"

class ReceiverConfigTest < Test::Unit::TestCase
  def setup
    fixtures_dir = File.expand_path(File.join(File.dirname(__FILE__), "fixtures"))
    options = YAML.load_file(File.join(fixtures_dir, "config-multi-site.yaml"))
    @receiver = GitHubPostReceiver.new(options)
  end

  data("github.com/clear-code/git-utils" => {
         :expected => {
           :to       => "commit@clear-code.com",
           :add_html => true,
           :from     => nil,
         },
         :params => {
           :domain     => "github.com",
           :owner      => "clear-code",
           :repository => "git-utils",
         }
       },
       "github.com/ranguba/examples" => {
         :expected => {
           :to       => "null@example.com",
           :add_html => true,
           :from     => nil,
         },
         :params => {
           :domain     => "github.com",
           :owner      => "ranguba",
           :repository => "examples",
         }
       },
       "github.com/ranguba/ranguba" => {
         :expected => {
           :to       => ["groonga-commit@rubyforge.org", "commit@clear-code.com"],
           :add_html => true,
           :from     => nil,
         },
         :params => {
           :domain     => "github.com",
           :owner      => "ranguba",
           :repository => "ranguba",
         }
       },
       "gitlab.example.net/support/firefox" => {
         :expected => {
           :to       => "support@example.net",
           :add_html => false,
           :from     => "support+null@example.net",
         },
         :params => {
           :domain     => "gitlab.example.net",
           :owner      => "support",
           :repository => "firefox",
         }
       },
       "gitlab.example.org/clear-code/other" => {
         :expected => {
           :to       => ["commit@example.org"],
           :add_html => false,
           :from     => "null@example.org",
         },
         :params => {
           :domain     => "gitlab.example.org",
           :owner      => "clear-code",
           :repository => "other",
         }
       },
       "gitlab.example.org/clear-code/test-project1" => {
         :expected => {
           :to       => "commit+test-project1@example.org",
           :add_html => true,
           :from     => "null@example.org",
         },
         :params => {
           :domain     => "gitlab.example.org",
           :owner      => "clear-code",
           :repository => "test-project1",
         }
       },
       "gitlab.example.org/clear-code/test-project2" => {
         :expected => {
           :to       => "commit+test-project2@example.org",
           :add_html => false,
           :from     => "null@example.org",
         },
         :params => {
           :domain     => "gitlab.example.org",
           :owner      => "clear-code",
           :repository => "test-project2",
         }
       },
       "gitlab.example.org/support/thunderbird" => {
         :expected => {
           :to       => "support@example.org",
           :add_html => false,
           :from     => "null+support@example.org",
         },
         :params => {
           :domain     => "gitlab.example.org",
           :owner      => "support",
           :repository => "thunderbird",
         }
       },
       "ghe.example.com/clear-code/other" => {
         :expected => {
           :to       => ["commit@example.com"],
           :add_html => false,
           :from     => "null@example.com",
         },
         :params => {
           :domain     => "ghe.example.com",
           :owner      => "clear-code",
           :repository => "other",
         }
       },
       "ghe.example.com/clear-code/test-project1" => {
         :expected => {
           :to       => "commit+test-project1@example.com",
           :add_html => false,
           :from     => "null@example.com",
         },
         :params => {
           :domain     => "ghe.example.com",
           :owner      => "clear-code",
           :repository => "test-project1",
         }
       },
       "ghe.example.com/clear-code/test-project2" => {
         :expected => {
           :to       => "commit+test-project2@example.com",
           :add_html => false,
           :from     => "null@example.com",
         },
         :params => {
           :domain     => "ghe.example.com",
           :owner      => "clear-code",
           :repository => "test-project2",
         }
       },
       "ghe.example.com/support/thunderbird" => {
         :expected => {
           :to       => "support@example.com",
           :add_html => false,
           :from     => "null+support@example.com",
         },
         :params => {
           :domain     => "ghe.example.com",
           :owner      => "support",
           :repository => "thunderbird",
         }
       },
       "ghe.example.co.jp/clear-code/other" => {
         :expected => {
           :to       => ["commit@example.co.jp"],
           :add_html => true,
           :from     => "null@example.co.jp",
         },
         :params => {
           :domain     => "ghe.example.co.jp",
           :owner      => "clear-code",
           :repository => "other",
         }
       },
       "ghe.example.co.jp/clear-code/test-project1" => {
         :expected => {
           :to       => "commit+test-project1@example.co.jp",
           :add_html => true,
           :from     => "null@example.co.jp",
         },
         :params => {
           :domain     => "ghe.example.co.jp",
           :owner      => "clear-code",
           :repository => "test-project1",
         }
       },
       "ghe.example.co.jp/clear-code/test-project2" => {
         :expected => {
           :to       => "commit+test-project2@example.co.jp",
           :add_html => true,
           :from     => "null@example.co.jp",
         },
         :params => {
           :domain     => "ghe.example.co.jp",
           :owner      => "clear-code",
           :repository => "test-project2",
         }
       },
       "ghe.example.co.jp/support/thunderbird" => {
         :expected => {
           :to       => "support@example.co.jp",
           :add_html => true,
           :from     => "null+support@example.co.jp",
         },
         :params => {
           :domain     => "ghe.example.co.jp",
           :owner      => "support",
           :repository => "thunderbird",
         }
       })
  def test_repository_options(data)
    params = data[:params]
    domain = params[:domain]
    owner = params[:owner]
    repository = params[:repository]
    options = @receiver.__send__(:repository_options, domain, owner, repository)
    assert_options(data[:expected], options)
  end

  private
  def assert_options(expected, options)
    actual = {
      :to       => options[:to],
      :add_html => options[:add_html],
      :from     => options[:from],
    }
    assert_equal(expected, actual)
  end
end
