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
      desc "Build gems to prepare for a release. Requires TAG="
      task :build do
        require 'tmpdir'

        raise "You must specify a TAG" unless ENV['TAG']

        ReleaseOps.with_tmpdir(:prefix => 'zookeeper') do |tmpdir|
          tag = ENV['TAG']

          sh "git clone . #{tmpdir}"

          orig_dir = Dir.getwd

          cd tmpdir do
            sh "git co #{tag} && git reset --hard && git clean -fdx"

            ENV['JAVA_GEM'] = nil
            sh "gem build zookeeper.gemspec"
            sh "env JAVA_GEM=1 gem build zookeeper.gemspec"

            mv FileList['*.gem'], orig_dir
          end
        end
      end

      desc "Release gems that have been built"
      task :push do
        gems = FileList['*.gem']
        raise "No gemfiles to push!" if gems.empty?

        gems.each do |gem|
          sh "gem push #{gem}"
        end
      end

      task :clean do
        rm_rf FileList['*.gem']
      end

      task :all => [:build, :push, :clean]
    end
  end
end

task :clobber do
  rm_rf 'tmp'
end

# cargo culted from http://blog.flavorjon.es/2009/06/easily-valgrind-gdb-your-ruby-c.html
VALGRIND_BASIC_OPTS = '--num-callers=50 --error-limit=no --partial-loads-ok=yes --undef-value-errors=no --trace-children=yes'

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

  task :clobber do
    cd 'ext' do
      sh 'rake clobber'
    end

    Rake::Task['build'].invoke
  end
end

desc "Build C component"
task :build do
  cd 'ext' do
    sh "rake"
  end
end

task 'spec:run' => 'build:clean' unless defined?(::JRUBY_VERSION)

task 'ctags' do
  sh 'bundle-ctags'
end

# because i'm a creature of habit
task 'mb:test_all' => 'zk:test_all'


