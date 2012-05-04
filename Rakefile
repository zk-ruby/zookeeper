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


require File.expand_path('../lib/zookeeper/rake_tasks', __FILE__)

RUBY_NAMES = %w[1.8.7 1.9.2 jruby rbx 1.9.3]

Zookeeper::RakeTasks.define_test_tasks_for(*RUBY_NAMES)

task :default => 'zk:1.9.3'

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

