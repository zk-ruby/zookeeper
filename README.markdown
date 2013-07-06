# zookeeper #

[![Build Status](https://secure.travis-ci.org/zk-ruby/zookeeper.png?branch=master)](http://travis-ci.org/zk-ruby/zookeeper)

An interface to the Zookeeper cluster coordination server.

For a higher-level interface with a more convenient API and features such as locks, have a look at [ZK](https://github.com/zk-ruby/zk).

## Fork Safety! ##

As of 1.1.0, this library is fork-safe (which was not easy to accomplish). This means you can use it without worry in unicorn, resque, and whatever other fork-philic frameworks you sick little monkeys are using this week. The only rule is that after a fork(), you need to call `#reopen` on the client ASAP, because if you try to peform any other action, an exception will be raised. Other than that, there is no special action that is needed in the parent.

## Big Plans for 1.0 ##

The 1.0 release will feature a reorganization of the heirarchy. There will be a single top-level `Zookeeper` namespace (as opposed to the current layout, with 5-6 different top-level constants), and for the next several releases, there will be a backwards compatible require for users that still need to use the old names.

## License

Copyright 2008 Phillip Pearson, and 2010 Twitter, Inc. 
Licensed under the MIT License.  See the included LICENSE file.  

Portions copyright 2008-2010 the Apache Software Foundation, licensed under the
Apache 2 license, and used with permission.

Portions contributed to the open source community by HPDC, L.P.

## Install

sudo gem install zookeeper

### rbenv is awesome

UPDATE: this appears to have been fixed by @eric in [this patch](http://git.io/PEPgnA). If you use rbenv, please report any issues, but I believe it should work now.

Let me start out by saying I prefer rvm, and that I really don't know a whole lot about linking on OS X. Or Linux. Any suggestions or constructive insults would be greatly appreciated if you have insight into what i'm doing wrong here.

So, it seems that [ruby-build][] doesn't use `--enable-shared` by default. I'm told this is for speed. 

If you run into problems with installing this gem (specifically with linking ex. `Undefined symbols for architecture x86_64`) and you're using rbenv, for now you need to ensure that your ruby was built with `--enable-shared`. I'm sorry for the inconvenience. (no, really)

```shell
~ $ CONFIGURE_OPTS='--enable-shared --disable-install-doc' rbenv install 1.9.3-p194
```

[ruby-build]: https://github.com/sstephenson/ruby-build

### A note for REE users

The zookeeper client is required to send a heartbeat packet every N seconds to the server. If it misses its deadline 3 times in a row, the session will be lost. The way the client is implemented in versions `>= 1.2`, a *ruby* thread acts as the event thread (this was necessary to provide a fork-safe client with a parent process that is able to preserve state). Some users have reported issues where under load in "massive codebases," they have problems where calls will time out. Given the nature of the thread scheduler in 1.8, one should be careful if upgrading from `0.4.4` to `>= 1.2`.

## Usage

Connect to a server:

	require 'rubygems'
	require 'zookeeper'
	z = Zookeeper.new("localhost:2181")
	z.get_children(:path => "/")

## Idioms

The following methods are initially supported:
* `get`
* `set`
* `get_children`
* `stat`
* `create`
* `delete`
* `get_acl`
* `set_acl`

All support async callbacks. `get`, `get_children` and `stat` support both watchers and callbacks.

Calls take a dictionary of parameters. With the exception of set\_acl, the only required parameter is `:path`. Each call returns a dictionary with at minimum two keys :req\_id and :rc.

### A Bit about this repository ###

Twitter's open source office was kind enough to transfer this repository to facilitate development and administration of this repository. The `zookeeper` gem's last three releases were recorded in branches `v0.4.2`, `v0.4.3` and `v0.4.4`. Releases of the `slyphon-zookeeper` gem were cut off of the fork, and unfortunately (due to an oversight on my part) were tagged with unrelated versions. Those were tagged with names `release/0.9.2`. 

The plan is to keep the `slyphon-zookeeper` tags, and to tag the `zookeeper` releases `twitter/release/0.4.x`.

Further work will be carried out on this repository. The `0.9.3` release of the zookeeper gem will be released under the 'zookeeper' name, and will bring the two divergent (conceptual) branches of development together.



