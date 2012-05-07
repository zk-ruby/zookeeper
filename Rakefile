# def gemset_name
#   ENV.fetch('GEM_HOME').split('@').last
# end

GEM_FILES = ReleaseOps.gem_files

# need to releaase under both names until ZK is updated to use just 'zookeeper'
GEM_NAMES = %w[zookeeper slyphon-zookeeper]

release_ops_path = File.expand_path('../releaseops/lib', __FILE__)

# if the special submodule is availabe, use it
# we use a submodule because it doesn't depend on anything else (*cough* bundler)
# and can be shared across projects
#
if File.exists?(release_ops_path)
  require File.join(release_ops_path, 'releaseops')

  # sets up the multi-ruby zk:test_all rake tasks
  ReleaseOps::TestTasks.define_for(*%w[1.8.7 1.9.2 jruby rbx ree 1.9.3])

  # sets up the task :default => 'spec:run' and defines a simple
  # "run the specs with the current rvm profile" task
  ReleaseOps::TestTasks.define_simple_default_for_travis

  # Define a task to run code coverage tests
  ReleaseOps::TestTasks.define_simplecov_tasks

  # set up yard:server, yard:gems, and yard:clean tasks 
  # for doing documentation stuff
  ReleaseOps::YardTasks.define

  task :clean => 'yard:clean'

  namespace :zk do
    namespace :gems do
      task :build do
        require 'tmpdir'

        raise "You must specify a TAG" unless ENV['TAG']

        tmpdir = File.join(Dir.tmpdir, "zookeeper.#{rand(1_000_000)}_#{$$}_#{Time.now.strftime('%Y%m%d%H%M%S')}")
        tag = ENV['TAG']

        sh "git clone . #{tmpdir}"

        orig_dir = Dir.getwd

        cd tmpdir do
          sh "git co #{tag} && git reset --hard && git clean -fdx"

          GEM_NAMES.each do |gem_name|
            ENV['JAVA_GEM'] = nil
            sh "rvm 1.8.7 do env ZOOKEEPER_GEM_NAME='#{gem_name}' gem build zookeeper.gemspec"
            sh "rvm 1.8.7 do env JAVA_GEM=1 ZOOKEEPER_GEM_NAME='#{gem_name}' gem build zookeeper.gemspec"
          end

          mv ReleaseOps.gem_files, orig_dir
        end
      end

      task :push => :build do
        raise "No gemfiles to push!" if ReleaseOps.gem_files.empty?

        ReleaseOps.gem_files.each do |gem|
          sh "gem push #{gem}"
        end
      end

      task :clean do
        rm_rf ReleaseOps.gem_files
      end

      task :all => [:build, :push, :clean]
    end
  end
end

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

task 'spec:run' => 'build:clean' unless defined?(::JRUBY_VERSION)

