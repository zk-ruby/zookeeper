
require 'mkmf'
require 'rbconfig'

HERE = File.expand_path(File.dirname(__FILE__))
BUNDLE = Dir.glob("zkc-*.tar.gz").first
BUNDLE_PATH = "c"

$CFLAGS = "#{RbConfig::CONFIG['CFLAGS']} #{$CFLAGS}".gsub("$(cflags)", "").gsub("-arch ppc", "")
$LDFLAGS = "#{RbConfig::CONFIG['LDFLAGS']} #{$LDFLAGS}".gsub("$(ldflags)", "").gsub("-arch ppc", "")
$CXXFLAGS = " -std=gnu++98 #{$CFLAGS}"
$CPPFLAGS = $ARCH_FLAG = $DLDFLAGS = ""

if ENV['DEBUG']
  puts "Setting debug flags."
  $CFLAGS << " -O0 -ggdb3 -DHAVE_DEBUG"
  $EXTRA_CONF = " --enable-debug"
  $CFLAGS.gsub!(/ -O[^0] /, ' ')
end

$includes = " -I#{HERE}/include"
$libraries = " -L#{HERE}/lib -L#{RbConfig::CONFIG['libdir']}"
$CFLAGS = "#{$includes} #{$libraries} #{$CFLAGS}"
$LDFLAGS = "#{$libraries} #{$LDFLAGS}"
$LIBPATH = ["#{HERE}/lib"]
$DEFLIBPATH = []

Dir.chdir(HERE) do
  if File.exist?("lib")
    puts "Zkc already built; run 'rake clean' first if you need to rebuild."
  else
    puts "Building zkc."
    puts(cmd = "tar xzf #{BUNDLE} 2>&1")
    raise "'#{cmd}' failed" unless system(cmd)

    Dir.chdir(BUNDLE_PATH) do        
      puts(cmd = "env CC=gcc CXX=g++ CFLAGS='-fPIC #{$CFLAGS}' LDFLAGS='-fPIC #{$LDFLAGS}' ./configure --prefix=#{HERE} --without-cppunit --disable-dependency-tracking #{$EXTRA_CONF} 2>&1")
      raise "'#{cmd}' failed" unless system(cmd)
      puts(cmd = "make CXXFLAGS='#{$CXXFLAGS}' CFLAGS='-fPIC #{$CFLAGS}' LDFLAGS='-fPIC #{$LDFLAGS}' || true 2>&1")
      raise "'#{cmd}' failed" unless system(cmd)
      puts(cmd = "make install || true 2>&1")
      raise "'#{cmd}' failed" unless system(cmd)
    end

    system("rm -rf #{BUNDLE_PATH}") unless ENV['DEBUG'] or ENV['DEV']
  end
end

# Absolutely prevent the linker from picking up any other zookeeper_mt
Dir.chdir("#{HERE}/lib") do
  system("cp -f libzookeeper_mt.a libzookeeper_mt_gem.a") 
  system("cp -f libzookeeper_mt.la libzookeeper_mt_gem.la") 
end
$LIBS << " -lzookeeper_mt_gem"

create_makefile 'zookeeper_c'
