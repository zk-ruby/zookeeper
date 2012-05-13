#!/usr/bin/env ruby

require 'zookeeper'
require File.expand_path('../spec/support/zookeeper_spec_helpers', __FILE__)

class CauseAbort
  include Zookeeper::Logger
  include Zookeeper::SpecHelpers

  attr_reader :path, :pids_root, :data

  def initialize
    @path = "/_zktest_"
    @pids_root = "#{@path}/pids"
    @data = 'underpants'
  end

  def before
    @zk = Zookeeper.new('localhost:2181')
    rm_rf(@zk, path)
    logger.debug { "----------------< BEFORE: END >-------------------" }
  end

  def process_alive?(pid)
    Process.kill(0, @pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_for_child_safely(pid, timeout=5)
    time_to_stop = Time.now + timeout

    until Time.now > time_to_stop
      if a = Process.wait2(@pid, Process::WNOHANG)
        return a.last
      else
        sleep(0.01)
      end
    end

    nil
  end

  def try_pause_and_resume
    @zk.pause
    logger.debug { "paused" }
    @zk.resume
    logger.debug { "resumed" }
    @zk.close
    logger.debug { "closed" }
  end

  def run_test
    logger.debug { "----------------< TEST: BEGIN >-------------------" }
    @zk.wait_until_connected

    mkdir_p(@zk, pids_root)

    # the parent's pid path
    @zk.create(:path => "#{pids_root}/#{$$}", :data => $$.to_s)

    @latch = Zookeeper::Latch.new
    @event = nil

    cb = proc do |h|
      logger.debug { "watcher called back: #{h.inspect}" }
      @event = h
      @latch.release
    end

    @zk.stat(:path => "#{pids_root}/child", :watcher => cb)

    logger.debug { "------------------->   FORK   <---------------------------" }

    @pid = fork do
      rand_sleep = rand()

      $stderr.puts "sleeping for rand_sleep: #{rand_sleep}"
      sleep(rand_sleep)

      logger.debug { "reopening connection in child: #{$$}" }
      @zk.reopen
      logger.debug { "creating path" }
      rv = @zk.create(:path => "#{pids_root}/child", :data => $$.to_s)
      logger.debug { "created path #{rv[:path]}" }
      @zk.close

      logger.debug { "close finished" }
      exit!(0)
    end

    event_waiter_th = Thread.new do
      @latch.await(5) unless @event 
      @event
    end

    logger.debug { "waiting on child #{@pid}" }

    status = wait_for_child_safely(@pid)
    raise "Child process did not exit, likely hung"  unless status

    if event_waiter_th.join(5) == event_waiter_th
      logger.warn { "event waiter has not received events" }
    end

    exit(@event.nil? ? 1 : 0)
  end

  def run
    before
    run_test
#     try_pause_and_resume
  end
end

CauseAbort.new.run
