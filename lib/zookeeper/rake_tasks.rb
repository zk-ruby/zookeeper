require 'rake'
require 'rake/tasklib'

module Zookeeper
  # @private
  module RakeTasks
    def self.define_test_tasks_for(*rubies)
      rubies.each do |r|

        TestOneRuby.new(:name => r) do |tor|
          yield tor if block_given?
        end
      end
    end

    class TestOneRuby < ::Rake::TaskLib
      include ::Rake::DSL if defined?(::Rake::DSL)

      DEFAULT_RVM_RUBY_NAME = '1.9.3'

      # defaults to 'zk', test tasks will be built under this
      attr_accessor :namespace

      # the name of the task
      # (tasks will be 'zk:1.9.3:run_rspec')
      #
      # this is mainly here so that the rvm ruby name rbx-2.0.testing 
      # will have its tasks defined as 'zk:rbx'
      attr_accessor :name

      # what is the rvm name we should use for testing? (i.e. could be an alias)
      # defaults to {#name}
      attr_accessor :rvm_ruby_name

      # any extra environment variables?
      attr_accessor :env

      # gemset name to use, deafults to the name of the gemspec in the top of the
      # project directory (minus the .gempsec)
      attr_accessor :gemset_name

      # @private
      attr_reader :ruby_with_gemset,       
        :create_gemset_name,
        :clobber_task_name,
        :clean_task_name,
        :build_task_name,
        :bundle_task_name,
        :rspec_task_name,
        :phony_gemfile_link_name,
        :phony_gemfile_lock_name


      def self.default_gemset_name
        ary = Dir['*.gemspec']
        raise 'No gemspec found' if ary.empty?
        ary.first[/(.+)\.gemspec\Z/, 1]
      end

      def initialize(opts={})
        @namespace      = 'zk'
        @name           = nil
        @env            = {}
        @rvm_ruby_name  = nil
        @gemset_name    = nil

        opts.each { |k,v| __send__(:"#{k}=", v) }

        yield self if block_given?

        @gemset_name    ||= self.class.default_gemset_name
        
        # XXX: add an exception just for me in here (yes, i know this is naughty)
        #      or else i'd have to do this in every zk variant i want to test
        #      (like i have to now)

        unless @rvm_ruby_name
          @rvm_ruby_name = 'rbx-2.0.testing' if @name == 'rbx'
        end

        @rvm_ruby_name  ||= name

        @ruby_with_gemset         = "#{@rvm_ruby_name}@#{@gemset_name}"
        @create_gemset_name       = "#{namespace}:#{name}:create_gemset"
        @clobber_task_name        = "#{namespace}:#{name}:clobber"
        @clean_task_name          = "#{namespace}:#{name}:clean"
        @build_task_name          = "#{namespace}:#{name}:build"
        @bundle_task_name         = "#{namespace}:#{name}:bundle_install"
        @rspec_task_name          = "#{namespace}:#{name}:run_rspec"
        @phony_gemfile_link_name  = "Gemfile.#{name}"
        @phony_gemfile_lock_name  = "#{phony_gemfile_link_name}.lock"

        define_tasks
      end

      private
        def need_ext_build?
          name != 'jruby' && File.directory?('./ext')
        end

        def define_tasks
          file phony_gemfile_link_name do
            # apparently, rake doesn't deal with symlinks intelligently :P
            ln_s('Gemfile', phony_gemfile_link_name) unless File.symlink?(phony_gemfile_link_name)
          end

          task :clean do
            rm_rf [phony_gemfile_lock_name, phony_gemfile_lock_name]
          end

          task create_gemset_name do
            sh "rvm #{rvm_ruby_name} do rvm gemset create #{gemset_name}"
          end

          task clobber_task_name do
            if need_ext_build?
              cd 'ext' do
                sh "rake clobber"
              end
            end
          end

          task clean_task_name do
            if need_ext_build?
              cd 'ext' do
                sh "rake clean"
              end
            end
          end

          task build_task_name => [create_gemset_name, clean_task_name] do
            if need_ext_build?
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

          task "#{namespace}:#{name}" => rspec_task_name

          task "#{namespace}:test_all_rubies" => rspec_task_name

          unless Rake::Task.task_defined?("#{namespace}:test_all")
            task "#{namespace}:test_all" do
              require 'benchmark'
              t = Benchmark.realtime do
                Rake::Task["#{namespace}:test_all_rubies"].invoke
              end

              $stderr.puts "Test run took: #{t} s"
            end
          end
        end
    end
  end
end

