source 'https://rubygems.org'

gemspec

gem 'rake', '~> 0.9.0'

group :test do
  gem "rspec" , "~> 2.11"
  gem 'eventmachine', '1.0.0'
  gem 'evented-spec', '~> 0.9.0'
  gem 'zk-server', '~> 1.0', :git => 'https://github.com/zk-ruby/zk-server.git'
end

# ffs, :platform appears to be COMLETELY BROKEN so we just DO THAT HERE
# ...BY HAND

if RUBY_VERSION != '1.8.7' && !defined?(JRUBY_VERSION)
  gem 'simplecov', :group => :coverage, :require => false
  gem 'yard', '~> 0.8.0', :group => :docs
  gem 'redcarpet',        :group => :docs

  group :development do
    gem 'pry'
    gem 'guard',        :require => false
    gem 'guard-rspec',  :require => false
    gem 'guard-shell',  :require => false
  end
end

# vim:ft=ruby
