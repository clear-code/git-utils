# Web hook receiver

This is a Rack based web application that can process POST request from GitHub, GitLab and GHE.

* github-post-receiver.rb: Process GitHub/GitLab web hooks to send commit mails.
* gitlab-system-hooks-receiver.rb: Process GitLab system hook "project_create" event.

## Set up (Nginx + Unicorn)

Clone repository.

```
$ cd ~git-utils
$ sudo -u git-utils -H git clone https://github.com/clear-code/git-utils.git
```

Prepare following files.

/etc/nginx/sites-enabled/git-utils:
```
upstream git-utils {
    server unix:/tmp/unicorn-git-utils.sock;
}

server {
    listen 80;
    server_name git-utils.example.com;
    access_log /var/log/nginx/git-utils.example.com-access.log combined;

    root /srv/www/git-utils;
    index index.html;

    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $http_host;
    #proxy_redirect off;

    location / {
        root /home/git-utils/git-utils/github-post-receiver/public;
        include maintenance;
        if (-f $request_filename){
            break;
        }
        if (!-f $request_filename){
            proxy_pass http://git-utils;
            break;
        }
    }
}
```

/home/git-utils/git-utils/github-post-receiver/unicorn.conf:
```
# -*- ruby -*-
worker_processes 2
working_directory "/home/git-utils/git-utils/github-post-receiver"
listen '/tmp/unicorn-github-post-receiver.sock', :backlog => 1
timeout 120
pid 'tmp/pids/unicorn.pid'
preload_app true
stderr_path 'log/unicorn.log'
stdout_path "log/stdout.log"
user "git-utils", "git-utils"
```

/home/git-utils/git-utils/github-post-receiver/Gemfile:
```
source "https://rubygems.org"

gem "rack"
gem "unicorn"
gem "racknga"
```

/home/git-utils/bin/github-post-receiver:
```
#! /bin/zsh
BASE_DIR=/home/git-utils/git-utils/github-post-receiver
export RACK_ENV=production
cd  $BASE_DIR
rbenv version

command=$1

function start() {
  mkdir -p $BASE_DIR/tmp/pids
  mkdir -p $BASE_DIR/log
  bundle exec unicorn -D -c unicorn.conf config.ru
}

function stop() {
  kill $(cat $BASE_DIR/tmp/pids/unicorn.pid)
}

function restart() {
  kill -USR2 $(cat $BASE_DIR/tmp/pids/unicorn.pid)
}

$command
```

Install gems.

```
$ sudo -u git-utils -H bundle install --path vendor/bundle
```

Run the application.

```
$ sudo -u git-utils -H ~git-utils/bin/github-post-receiver start
```

## Set up (Apache + Passenger)

On Debian GNU/Linux wheezy.

See also [Phusion Passenger users guide, Apache version](https://www.phusionpassenger.com/documentation/Users%20guide%20Apache.html).

Clone repository.

```
$ cd ~git-utils
$ sudo -u git-utils -H git clone https://github.com/clear-code/git-utils.git
```

Install Passenger.
Following command can display configurations for your environment.

```
$ sudo gem install passenger
```

Prepare following files.

/etc/apache2/mods-available.conf:
```
PassengerRoot /path/to/passenger-x.x.x
PassengerRuby /path/to/ruby

PassengerMaxRequests 100
```

/etc/apache2/mods-available.load:
```
LoadModule passenger_module /path/to/mod_passenger.so
```

/etc/apache2/sites-available/git-utils:
```
<VirtualHost *:80>
  ServerName git-utils.example.com
  DocumentRoot /home/git-utils/git-utils/github-post-receiver/public
  <Directory /home/git-utils/git-utils/github-post-receiver/public>
     AllowOverride all
     Options -MultiViews
  </Directory>

  ErrorLog ${APACHE_LOG_DIR}/git-utils_error.log
  CustomLog ${APACHE_LOG_DIR}/git-utils_access.log combined

  AllowEncodedSlashes On
  AcceptPathInfo On
</VirtualHost>
```

Enable the module.

```
$ sudo a2enmod passenger
```

Enable the virtual host.

```
$ sudo a2ensite git-utils
```

Restart web server.

```
$ sudo service apache2 restart
```

## Configuration

You need to edit config.yaml to configure this web application.
See config.yaml.example and test codes.

## Add system hook

See "Admin area" -> "Hooks".

