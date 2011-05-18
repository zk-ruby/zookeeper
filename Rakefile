namespace :mb do
  task :build_gems do
    sh "gem build slyphon-zookeeper.gemspec"
    ENV['JAVA_GEM'] = '1'
    sh "gem build slyphon-zookeeper.gemspec"
  end
end

