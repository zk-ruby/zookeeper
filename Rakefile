def gemset_name
  ENV.fetch('GEM_HOME').split('@').last
end

namespace :mb do
  task :build_gems do
    sh "rvm 1.8.7 do gem build slyphon-zookeeper.gemspec"
    ENV['JAVA_GEM'] = '1'
    sh "rvm 1.8.7 do gem build slyphon-zookeeper.gemspec"
  end
end

%w[1.8.7 1.9.2 1.9.3 jruby].each do |rvm_ruby|
  ruby_with_gemset = "#{rvm_ruby}@#{gemset_name}"

  clobber_task_name = "mb:#{rvm_ruby}:clobber"
  build_task_name   = "mb:#{rvm_ruby}:build"
  bundle_task_name  = "mb:#{rvm_ruby}:bundle_install"
  rspec_task_name   = "mb:#{rvm_ruby}:run_rspec"

  task clobber_task_name do
    unless rvm_ruby == 'jruby'
      cd 'ext' do
        sh "rake clobber"
      end
    end
  end

  task build_task_name => clobber_task_name do
    unless rvm_ruby == 'jruby'
      cd 'ext' do
        sh "rvm #{ruby_with_gemset} do rake build"
      end
    end
  end

  task bundle_task_name => build_task_name do
    rm_f 'Gemfile.lock'
    sh "rvm #{ruby_with_gemset} do bundle install"
  end

  task rspec_task_name => bundle_task_name do
    sh "rvm #{ruby_with_gemset} do bundle exec rspec spec"
  end

  task "mb:test_all_rubies" => rspec_task_name
end


