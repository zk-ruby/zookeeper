require 'spec_helper'

describe 'fork hooks' do
  def safe_kill_process(signal, pid)
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end

  after do
    Zookeeper::Forked.clear!

    if @pid
      safe_kill_process('KILL', @pid)
    end
  end

  describe 'fork with a block' do
    it %[should call the after_fork_in_child hooks in the child] do
      child_hook_called = false

      hook_order = []

      Zookeeper.prepare_for_fork { hook_order << :prepare }
      Zookeeper.after_fork_in_parent { hook_order << :parent }
      Zookeeper.after_fork_in_child { hook_order << :child }

      @pid = fork do
        unless hook_order.first == :prepare
          $stderr.puts "hook order wrong! #{hook_order.inspect}"
          exit! 2
        end

        unless hook_order.last == :child
          $stderr.puts "hook order wrong! #{hook_order.inspect}"
          exit! 3
        end

        exit! 0
      end

      hook_order.first.should == :prepare
      hook_order.last.should == :parent

      _, st = Process.wait2(@pid)
      st.exitstatus.should == 0

      st.should be_exited
      st.should be_success
    end
  end
end

