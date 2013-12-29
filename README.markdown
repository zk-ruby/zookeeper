# zookeeper #

[![Build Status](https://secure.travis-ci.org/zk-ruby/zookeeper.png?branch=master)](http://travis-ci.org/zk-ruby/zookeeper)

A low-level interface to the [Apache ZooKeeper](https://zookeeper.apache.org/) cluster coordination server.

For a higher-level interface with a more convenient API and features such as locks, have a look at [ZK](https://github.com/zk-ruby/zk).

## Install

```
gem install zookeeper
```

Installation does not work on OS X Mavericks.

## Usage

Connect to a server:

```ruby
require 'rubygems'
require 'zookeeper'
z = Zookeeper.new("localhost:2181")
z.get_children(:path => "/")
```

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

### Fork Safety! ##

As of 1.1.0, this library is fork-safe. This means you can use it without worry in unicorn, resque, and other fork-philic frameworks. The only rule is that after a fork(), you need to call `#reopen` on the client ASAP, because if you try to peform any other action, an exception will be raised. Other than that, there is no special action that is needed in the parent.

## License

Copyright 2008 Phillip Pearson, and 2010 Twitter, Inc. 
Licensed under the MIT License.  See the included LICENSE file.  

Portions copyright 2008-2010 the Apache Software Foundation, licensed under the
Apache 2 license, and used with permission.

Portions contributed to the open source community by HPDC, L.P.
