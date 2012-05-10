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
      called_back = false

      Zookeeper.after_fork_in_child { called_back = true }

      @pid = fork do
        if called_back
          exit! 0
        else
          exit! 1
        end
      end

      _, st = Process.wait2(@pid)
      st.should be_exited
      st.should be_success
    end
  end
end

