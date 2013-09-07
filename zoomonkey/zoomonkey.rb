require 'zookeeper'
require 'zk-server'
require 'fileutils'
require 'tmpdir'

SLEEP_TIME = 30
STDOUT.sync = true

if ENV['DEBUG']
  def zookeeper_logger(from)
    l = Logger.new(STDOUT)
    l.formatter = proc do |sev, time, c, msg|
      "t=#{time.to_i} from=#{from} level=#{sev.downcase} message=#{msg.inspect}\n"
    end
    l
  end

  Zookeeper.logger = zookeeper_logger('zookeeper')
  Zookeeper.set_debug_level(Zookeeper::ZOO_LOG_LEVEL_DEBUG)
  Zookeeper::CZookeeper.set_zkrb_debug_level(Zookeeper::ZOO_LOG_LEVEL_DEBUG)
  Zookeeper::CZookeeper.zoo_set_log_level(Zookeeper::ZOO_LOG_LEVEL_DEBUG)
end

class Worker
  def initialize(body = nil, &block)
    raise ArgumentError, "Cannot include both body and block" if body && block
    @body = body || block
  end

  def body
    @body || method(:call)
  end

  def start
    @thread = Thread.new do
      Thread.current.abort_on_exception = true
      body.call
    end
  end

  def stop
    if @thread
      @thread.kill
      @thread = nil
    end
  end

  def join
    if @thread
      @thread.join
    end
  end
end



base_dir = Dir.mktmpdir('zk-server-cluster')
num_cluster = 3
cluster = ZK::Server::Cluster.new(num_cluster, :base_dir => base_dir)

class Reader < Worker
  def initialize(zookeeper_hosts)
    @zookeeper_hosts = zookeeper_hosts
    @log_from = :reader
  end

  def call
    client = Zookeeper.new(@zookeeper_hosts)
    client.wait_until_connected

    while true
      error = nil
      t = Benchmark.realtime do
        begin
          client.get(:path => "/test")
        rescue => e
          error = e
        end
      end

      msg = "session_id=#{client.session_id} state=#{client.state_by_value(client.state)} time=#{"%0.4f" % t}"
      if error
        msg << " error=#{error.class} error_message=#{error.to_s.inspect}"
        msg << " closed=#{client.closed?} running=#{client.running?} shutting_down=#{client.shutting_down?}"
      end

      log msg

      sleep 1
    end
  end

  def log(message)
    puts "t=#{Time.now.to_i} from=#{@log_from} #{message}\n"
  end
end

class Writer < Worker
  def initialize(zookeeper_hosts)
    @zookeeper_hosts = zookeeper_hosts
    @log_from = :writer
  end

  def call
    client = Zookeeper.new(@zookeeper_hosts)
    client.wait_until_connected

    while true
      error = nil
      t = Benchmark.realtime do
        begin
          client.create(:path => "/test", :data => '') rescue client.set(:path => "/test", :data => '')
        rescue => e
          error = e
        end
      end

      msg = "session_id=#{client.session_id} state=#{client.state_by_value(client.state)} time=#{"%0.4f" % t}"
      msg << " error=#{error.class} error_message=#{error.to_s.inspect}" if error
      log msg

      sleep 1
    end
  end

  def log(message)
    puts "t=#{Time.now.to_i} from=#{@log_from} #{message}\n"
  end
end

class ZooMonkey < Worker
  attr_reader :cluster

  def initialize(cluster)
    @cluster = cluster
    @log_from = :server
  end

  def call
    while true
      sleep SLEEP_TIME

      cluster.processes.each do |server|
        log "pid=#{server.pid} client_port=#{server.client_port} action=pausing"
        server.kill "STOP"
        sleep SLEEP_TIME

        log "pid=#{server.pid} client_port=#{server.client_port} action=resuming"
        server.kill "CONT"
        sleep SLEEP_TIME
      end
    end
  end

  def log(message)
    puts "t=#{Time.now.to_i} from=#{@log_from} #{message}\n"
  end
end

begin
  cluster.run

  zookeeper_hosts = cluster.processes.map { |p| "localhost:#{p.client_port}" }.join(',')

  reader = Reader.new(zookeeper_hosts)
  reader.start

  # writer = Writer.new(zookeeper_hosts)
  # writer.start

  monkey = ZooMonkey.new(cluster)
  monkey.start

  reader.join
  writer.join
  monkey.join
ensure
  cluster.clobber!
  FileUtils.remove_entry(base_dir)
end
