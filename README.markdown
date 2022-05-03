# zookeeper #

![Build Status](https://github.com/zk-ruby/zookeeper/actions/workflows/build.yml/badge.svg)


An interface to the Zookeeper cluster coordination server.

For a higher-level interface with a more convenient API and features such as locks, have a look at [ZK](https://github.com/zk-ruby/zk).

## Fork Safety! ##

As of 1.1.0, this library is fork-safe (which was not easy to accomplish). This means you can use it without worry in unicorn, resque, and whatever other fork-philic frameworks you sick little monkeys are using this week. The only rule is that after a fork(), you need to call `#reopen` on the client ASAP, because if you try to peform any other action, an exception will be raised. Other than that, there is no special action that is needed in the parent.

## License

Copyright 2008 Phillip Pearson, and 2010 Twitter, Inc.
Licensed under the MIT License.  See the included LICENSE file.

Portions copyright 2008-2010 the Apache Software Foundation, licensed under the
Apache 2 license, and used with permission.

Portions contributed to the open source community by HPDC, L.P.

## Install

sudo gem install zookeeper

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



