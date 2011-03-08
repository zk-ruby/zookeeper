# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.name        = "slyphon-zookeeper"
  s.version     = '0.1.4'

  s.authors     = ["Phillip Pearson", "Eric Maland", "Evan Weaver", "Brian Wickman", "Jonathan D. Simms"]
  s.email       = ["slyphon@gmail.com"]
  s.summary     = %q{twitter's zookeeper client}
  s.description = s.summary

  s.add_development_dependency "rspec", ">= 2.0.0"
  s.add_development_dependency 'flexmock', '~> 0.8.11'

  s.files         = `git ls-files`.split("\n")
  s.require_paths = ["lib"]

  if ENV['JAVA_GEM']
    s.platform = 'java'
    s.add_runtime_dependency('slyphon-log4j',         '= 1.2.15')
    s.add_runtime_dependency('slyphon-zookeeper_jar', '= 3.3.1')
    s.require_paths += %w[java]
  else
    s.require_paths += %w[ext]
    s.extensions = 'ext/extconf.rb'
  end

  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
end
