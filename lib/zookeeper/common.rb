require 'zookeeper/exceptions'
require 'zookeeper/common/queue_with_pipe'

module Zookeeper
module Common
  def event_dispatch_thread?
    @dispatcher && (@dispatcher == Thread.current)
  end

private
  def setup_dispatch_thread!
    @mutex.synchronize do
      if @dispatcher
        logger.debug { "dispatcher already running" }
        return
      end

      logger.debug { "starting dispatch thread" }

      @dispatcher = Thread.new(&method(:dispatch_thread_body))
    end
  end
  
  # this method is part of the reopen/close code, and is responsible for
  # shutting down the dispatch thread. 
  #
  # @dispatcher will be nil when this method exits
  #
  def stop_dispatch_thread!(timeout=2)
    logger.debug { "#{self.class}##{__method__}" }

    if @dispatcher
      if @dispatcher.join(0)
        @dispatcher = nil
        return
      end

      @mutex.synchronize do
        event_queue.graceful_close!

        # we now release the mutex so that dispatch_next_callback can grab it
        # to do what it needs to do while delivering events
        #
        @dispatch_shutdown_cond.wait

        # wait for another timeout sec for the thread to join
        until @dispatcher.join(timeout)
          logger.error { "Dispatch thread did not join cleanly, waiting" }
        end
        @dispatcher = nil
      end
    end
  end

  def get_next_event(blocking=true)
    @event_queue.pop(!blocking).tap do |event|
      logger.debug { "#{self.class}##{__method__} delivering event #{event.inspect}" }
    end
  rescue ThreadError
    nil
  end

  def dispatch_next_callback(hash)
    return nil unless hash

    logger.debug { "get_next_event returned: #{prettify_event(hash).inspect}" }
    
    is_completion = hash.has_key?(:rc)
    
    hash[:stat] = Zookeeper::Stat.new(hash[:stat]) if hash.has_key?(:stat)
    hash[:acl] = hash[:acl].map { |acl| Zookeeper::ACLs::ACL.new(acl) } if hash[:acl]
    
    callback_context = @req_registry.get_context_for(hash)

    if callback_context
      callback = is_completion ? callback_context[:callback] : callback_context[:watcher]

      hash[:context] = callback_context[:context]

      if callback.respond_to?(:call)
        callback.call(hash)
      else
        # puts "dispatch_next_callback found non-callback => #{callback.inspect}"
      end
    else
      logger.warn { "Duplicate event received (no handler for req_id #{hash[:req_id]}, event: #{hash.inspect}" }
    end
    true
  end

  def dispatch_thread_body
    while true
      begin
        dispatch_next_callback(get_next_event(true))
      rescue QueueWithPipe::ShutdownException
        logger.info { "dispatch thread exiting, got shutdown exception" }
        return
      rescue Exception => e
        $stderr.puts ["#{e.class}: #{e.message}", e.backtrace.map { |n| "\t#{n}" }.join("\n")].join("\n")
      end
    end
  ensure
    signal_dispatch_thread_exit!
  end

  def signal_dispatch_thread_exit!
    @mutex.synchronize do
      logger.debug { "dispatch thread exiting!" }
      @dispatch_shutdown_cond.broadcast
    end
  end

  def prettify_event(hash)
    hash.dup.tap do |h|
      # pretty up the event display
      h[:type]    = Zookeeper::Constants::EVENT_TYPE_NAMES.fetch(h[:type]) if h[:type]
      h[:state]   = Zookeeper::Constants::STATE_NAMES.fetch(h[:state]) if h[:state]
      h[:req_id]  = :global_session if h[:req_id] == -1
    end
  end
end
end
