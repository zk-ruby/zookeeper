# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require 'zookeeper/version'

Gem::Specification.new do |s|
  s.name        = 'zookeeper'
  s.version     = Zookeeper::VERSION

  s.authors     = ["Phillip Pearson", "Eric Maland", "Evan Weaver", "Brian Wickman", "Neil Conway", "Jonathan D. Simms"]
  s.email       = ["slyphon@gmail.com"]
  s.summary     = %q{Apache ZooKeeper driver for Rubies}
  s.description = <<-EOS
A low-level multi-Ruby wrapper around the ZooKeeper API bindings. For a
friendlier interface, see http://github.com/slyphon/zk. Currently supported:
MRI: {1.8.7, 1.9.2, 1.9.3}, JRuby: ~> 1.6.7, Rubinius: 2.0.testing, REE 1.8.7.

This library uses version #{Zookeeper::DRIVER_VERSION} of zookeeper bindings.

  EOS

  s.homepage    = 'https://github.com/slyphon/zookeeper'

  s.files         = `git ls-files`.split("\n")
  s.require_paths = ["lib"]

  if ENV['JAVA_GEM'] or defined?(::JRUBY_VERSION)
    s.platform = 'java'
    s.add_runtime_dependency('slyphon-log4j',         '= 1.2.15')
    s.add_runtime_dependency('slyphon-zookeeper_jar', '= 3.3.5')
    s.require_paths += %w[java]
  else
    s.require_paths += %w[ext]
    s.extensions = 'ext/extconf.rb'
  end

  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
end
