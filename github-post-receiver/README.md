# Web hook receiver

This is a Rack based web application that can process POST request from GitHub/GitLab.

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

You need to edit config.yaml to configure this web application.
See test code for details.

## Set up (Apache + Passenger)

TODO


