require "rubygems"
require "zookeeper"

# A basic cloud-based YAML config library.  Ruby Zookeeper client example.
#
# If you pass in a file as 'zk:/foo.yml/blah' it will go out to zookeeper. 
# Otherwise the file is assumed to be local.  The yml file will get parsed
# and cached locally, and keys after the .yml get interpreted as keys into
# the YAML.
#
# e.g. get(zk:/config/service.yml/key1/key2/key3..) => 
#   zk.get(:path => /config/service.yml)
#   yaml <= YAML.parse(data)
#   yaml[key1][key2][key3]...
#
# If keys are unspecified, it returns the parsed YAML as one big object
#
# TODO if staleness is set to 0, read in YAML immediately before next
# get(...)

class CloudConfig
  class NodeNotFound < StandardError; end
  class BadPathError < StandardError; end

  DEFAULT_SERVERS = "localhost:2181"

  def initialize(zkservers = DEFAULT_SERVERS, staleness = 15)  # maximum allowed staleness in seconds
    @staleness = staleness
    @lock      = Mutex.new
    @zkservers = DEFAULT_SERVERS
    
    # cache
    @data      = {}
    @zkcb      = Zookeeper::WatcherCallback.new { dirty_callback(@zkcb.context) }
    @zk        = nil
  end

  def get(node)
    filename, keys = extract_filename(node)

    # read(filename) is potentially a zk call, so do not hold the lock during the read
    if @lock.synchronize { !@data.has_key?(filename) }
      d = YAML.load(read(filename))
      @lock.synchronize { @data[filename] = d }
    end
    
    # synchronized b/c we potentially have a background thread updating data nodes from zk
    # if keys is empty, return the whole file, otherwise roll up the keys
    @lock.synchronize {
      keys.empty? ? @data[filename] : keys.inject(@data[filename]) { |hash, key| hash[key] }
    }
  end

  # todo:
  #   factor get-and-watch into a different subsystem (so you can have
  #   polling stat() ops on local filesystem.)
  def read(yaml)
    # read yaml file and register watcher.  if watcher fires, set up
    # background thread to do read and update data.
    if yaml.match(/^zk:/)
      @zk ||= init_zk
      yaml = yaml['zk:'.length..-1] # strip off zk: from zk:/config/path.yml
      resp = get_and_register(yaml)

      if resp[:rc] != Zookeeper::ZOK
        @zk.unregister_watcher(resp[:req_id])
        raise NodeNotFound
      end
      
      resp[:data]
    else
      raise NodeNotFound unless File.exists?(yaml)
      File.read(yaml)
    end
  end

  def extract_filename(node)
    path_elements = node.split("/")
    
    yamlindex = path_elements.map{ |x| x.match("\.yml$") != nil }.index(true)
    raise BadPathError unless yamlindex
    
    yamlname = path_elements[0..yamlindex].join '/'
    yamlkeys = path_elements[(yamlindex+1)..-1]
    
    return yamlname, yamlkeys
  end
    
 private
  def init_zk
    Zookeeper.new(@zkservers)
  end
  
  def get_and_register(znode)
    @zk.get(:path => znode, :watcher => @zkcb,
                   :watcher_context => { :path => znode,
                                         :wait => rand(@staleness) })
  end
  
  def dirty_callback(context)
    path = context[:path]
    wait = context[:wait]

    # Fire off a background update that waits a randomized period of time up
    # to @staleness seconds.
    Thread.new do
      sleep wait
      background_update(path)
    end
  end

  def background_update(zkpath)
    # do a synchronous get/register a new watcher
    resp = get_and_register(zkpath)
    if resp[:rc] != Zookeeper::ZOK
      # puts "Unable to read #{zkpath} from Zookeeper!"  @logger.error
      zk.unregister_watcher(resp[:req_id])
    else
      # puts "Updating data."
      d = YAML.load(resp[:data])
      @lock.synchronize { @data["zk:#{zkpath}"] = d }
    end
  end
end

