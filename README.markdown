# zookeeper #

An interface to the Zookeeper cluster coordination server.

For a higher-level interface with a more convenient API and features such as locks, have a look at [ZK](https://github.com/slyphon/zk) (also available is [ZK-EventMachine](https://github.com/slyphon/zk-eventmachine) for those who prefer async).

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

## Usage

Connect to a server:

	require 'rubygems'
	require 'zookeeper'
	z = Zookeeper.new("localhost:2181")
	z.get_children(:path => "/")

## Idioms

The following methods are initially supported:
* get
* set
* get\_children
* stat
* create
* delete
* get\_acl
* set\_acl

All support async callbacks.  get, get\_children and stat support both watchers and callbacks.

Calls take a dictionary of parameters.  With the exception of set\_acl, the only required parameter is :path.  Each call returns a dictionary with at minimum two keys :req\_id and :rc.

### A Bit about this repository ###

Twitter's open source office was kind enough to transfer this repository to facilitate development and administration of this repository. The `zookeeper` gem's last three releases were recorded in branches `v0.4.2`, `v0.4.3` and `v0.4.4`. Releases of the `slyphon-zookeeper` gem were cut off of the fork, and unfortunately (due to an oversight on my part) were tagged with unrelated versions. Those were tagged with names `release/0.9.2`. 

The plan is to rename the `slyphon-zookeeper` tags to `slyzk/release/0.9.2`, and to tag the `zookeeper` releases `twitter/release/0.4.2`.

Further work will be carried out on this repository. The `0.9.2` release of the zookeeper gem will bring the two divergent (conceptual) branches of development together.



