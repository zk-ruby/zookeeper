require File.expand_path('../spec_helper', __FILE__)
require 'zookeeper/em_client'

gem 'evented-spec', '~> 0.9.0'
require 'evented-spec'


describe 'ZookeeperEM' do
  describe 'Client' do
    include EventedSpec::SpecHelper
    default_timeout 3.0

    def setup_zk
      @zk = ZookeeperEM::Client.new(Zookeeper.default_cnx_str)
      em do
        @zk.on_attached do
          yield
        end
      end
    end

    def teardown_and_done
      @zk.close do 
        logger.debug { "TEST: about to call done" }
        EM.next_tick do
          done
        end
      end
    end

    describe 'callbacks' do
      it %[should be called on the reactor thread] do
        cb = lambda do |h|
          EM.reactor_thread?.should be_true
          logger.debug { "called back on the reactor thread? #{EM.reactor_thread?}" }
          teardown_and_done
        end

        setup_zk do
          @zk.on_attached do |*|
            logger.debug { "on_attached called" }
            rv = @zk.get(:path => '/', :callback => cb) 
            logger.debug { "rv from @zk.get: #{rv.inspect}" }
          end
        end
      end
    end
  end
end


