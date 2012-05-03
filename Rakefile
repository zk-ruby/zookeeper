# def gemset_name
#   ENV.fetch('GEM_HOME').split('@').last
# end

GEM_FILES = FileList['*zookeeper-*.gem']

# need to releaase under both names until ZK is updated to use just 'zookeeper'
GEM_NAMES = %w[zookeeper slyphon-zookeeper]

namespace :mb do
  namespace :gems do
    task :build do
      GEM_NAMES.each do |gem_name|
        ENV['JAVA_GEM'] = nil
        sh "rvm 1.8.7 do env ZOOKEEPER_GEM_NAME='#{gem_name}' gem build zookeeper.gemspec"
        sh "rvm 1.8.7 do env JAVA_GEM=1 ZOOKEEPER_GEM_NAME='#{gem_name}' gem build zookeeper.gemspec"
      end
    end

    task :push => :build do
      raise "No gemfiles to push!" if GEM_FILES.empty?

      GEM_FILES.each do |gem|
        sh "gem push #{gem}"
      end
    end

    task :clean do
      rm_rf GEM_FILES
    end

    task :all => [:build, :push, :clean]
  end
end

gemset_name = 'zookeeper'

# this nonsense w/ tmp and the Gemfile is a bundler optimization

%w[1.8.7 1.9.2 jruby rbx 1.9.3].each do |ns_name|
  rvm_ruby = (ns_name == 'rbx') ? "rbx-2.0.testing" : ns_name

  ruby_with_gemset = "#{rvm_ruby}@#{gemset_name}"

  create_gemset_name  = "mb:#{ns_name}:create_gemset"
  clobber_task_name   = "mb:#{ns_name}:clobber"
  clean_task_name     = "mb:#{ns_name}:clean"
  build_task_name     = "mb:#{ns_name}:build"
  bundle_task_name    = "mb:#{ns_name}:bundle_install"
  rspec_task_name     = "mb:#{ns_name}:run_rspec"

  phony_gemfile_link_name = "Gemfile.#{ns_name}"
  phony_gemfile_lock_name = "#{phony_gemfile_link_name}.lock"

  file phony_gemfile_link_name do
    # apparently, rake doesn't deal with symlinks intelligently :P
    ln_s('Gemfile', phony_gemfile_link_name) unless File.symlink?(phony_gemfile_link_name)
  end

  task :clean do
    rm_rf [phony_gemfile_lock_name, phony_gemfile_lock_name]
  end

  task create_gemset_name do
    sh "rvm #{rvm_ruby} do rvm gemset create #{gemset_name}"
  end

  task clobber_task_name do
    unless rvm_ruby == 'jruby'
      cd 'ext' do
        sh "rake clobber"
      end
    end
  end

  task clean_task_name do
    unless rvm_ruby == 'jruby'
      cd 'ext' do
        sh "rake clean"
      end
    end
  end

  task build_task_name => [create_gemset_name, clean_task_name] do
    unless rvm_ruby == 'jruby'
      cd 'ext' do
        sh "rvm #{ruby_with_gemset} do rake build"
      end
    end
  end

  task bundle_task_name => [phony_gemfile_link_name, build_task_name] do
    sh "rvm #{ruby_with_gemset} do bundle install --gemfile #{phony_gemfile_link_name}"
  end

  task rspec_task_name => bundle_task_name do
    sh "rvm #{ruby_with_gemset} do env BUNDLE_GEMFILE=#{phony_gemfile_link_name} bundle exec rspec spec --fail-fast"
  end

  task "mb:#{ns_name}" => rspec_task_name

  task "mb:test_all_rubies" => rspec_task_name
end

task "mb:test_all" do
  require 'benchmark'
  t = Benchmark.realtime do
    Rake::Task['mb:test_all_rubies'].invoke
  end

  $stderr.puts "Test run took: #{t} s"
end

task :default => 'mb:1.9.3'

task :clobber do
  rm_rf 'tmp'
end

# cargo culted from http://blog.flavorjon.es/2009/06/easily-valgrind-gdb-your-ruby-c.html
VALGRIND_BASIC_OPTS = '--num-callers=50 --error-limit=no --partial-loads-ok=yes --undef-value-errors=no'

task 'valgrind' do
  cd 'ext' do
    sh "rake clean build"
  end

  sh "valgrind #{VALGRIND_BASIC_OPTS} bundle exec rspec spec"
end

namespace :build do
  task :clean do
    cd 'ext' do
      sh 'rake clean'
    end

    Rake::Task['build'].invoke
  end
end

task :build do
  cd 'ext' do
    sh "rake"
  end
end

