
guard 'rspec', :version => 2, :cli => '-c -f progress --fail-fast' do
  watch(%r{^spec/.+_spec.rb$})
  watch(%r{^lib/(.+)\.rb$}) { |m| %w[spec/zookeeper_spec.rb spec/chrooted_connection_spec.rb] }
  watch(%r{^ext/zookeeper_c.bundle}) { %w[spec/c_zookeeper_spec.rb] }
  watch(%r{^ext/zookeeper_base.rb}) { "spec" }
end

