source :rubygems

gemspec

gem 'rake', '~> 0.9.0'

platform :mri_19 do
  gem 'simplecov', :group => :coverage, :require => false
end

group :test do
  gem "rspec", "~> 2.8.0"
  gem 'eventmachine', '1.0.0.beta.4'
  gem 'evented-spec', '~> 0.9.0'

  gem 'zk-server', '~> 1.0.0'
end

platform :mri_19 do
  gem 'simplecov', :group => :coverage, :require => false
end

group :docs do
  gem 'yard', '~> 0.8.0'

  platform :mri_19 do
    gem 'redcarpet'
  end
end

group :development do
  gem 'pry'
end

# vim:ft=ruby
