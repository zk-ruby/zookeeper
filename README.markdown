zookeeper

An interface to the Zookeeper distributed configuration server.

For a higher-level interface with a slightly more convenient API and features
such as locks, have a look at [ZK](https://github.com/slyphon/zk) (also
available is [ZK-EventMachine](https://github.com/slyphon/zk-eventmachine) for
those who prefer async).

Most development work is taking place on the [slyphon-zookeeper][] fork, and that
code has regular releases and bug fixes.

[slyphon-zookeeper]: https://github.com/slyphon/zookeeper

## License

Copyright 2008 Phillip Pearson, and 2010 Twitter, Inc. Licensed under the
MIT License.  See the included LICENSE file.  Portions copyright 2008-2010
the Apache Software Foundation, licensed under the Apache 2 license, and
used with permission.

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

All support async callbacks.  get, get\_children and stat support both
watchers and callbacks.

Calls take a dictionary of parameters.  With the exception of set\_acl, the
only required parameter is :path.  Each call returns a dictionary with at
minimum two keys :req\_id and :rc.

