#!/usr/bin/env ruby

if ARGV.empty?
  $stderr.puts <<-EOS
Usage: #{File.basename(__FILE__)} file1 file2 file3

Fix references to Zookeeper classes and modules.

This script acts like sed and edits files in place (not saving backups,
as you *are* using source control and aren't a complete tool). 

if you have any doubts, *read the script*:
----------------------------------------------------------------------

#{File.read(__FILE__)}

  EOS

  exit 1
end


require 'tempfile'
require 'fileutils'

ARGV.each do |path|
  Tempfile.open(File.basename(path)) do |tmp|
    File.open(path) do |input|
      while line = input.gets
        tmp.puts line.gsub(/\bZookeeperStat::Stat\b/, 'Zookeeper::Stat').
          gsub(/\bZookeeper::(\w+)Callback\b/, 'Zookeeper::Callbacks::\1Callback').
          gsub(/\bZookeeperACLs::(ZOO_\w+)\b/, 'Zookeeper::Constants::\1').
          gsub(/\bZookeeperExceptions::ZookeeperException::(\w+)\b/, 'Zookeeper::Exceptions::\1').
          gsub(/\bZookeeper(Constants|Exceptions|Common|ACLs|Callbacks)\b/, 'Zookeeper::\1').
          gsub(/\bZookeeperException::(\w+)\b/, 'Exceptions::\1')

      end
    end

    tmp.fsync
    tmp.close

    FileUtils.mv(tmp.path, path)
  end
end

