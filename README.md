# rmk

rmk is a software construction tool with a mix of features of make, rake maven, Scons and gradle. Unlike these tools rmk follows the idea that translation rules are not configured but implemented like normal code. Make targets become simple method calls. All configuration parameters are passed explicitly.


## Features

* Build scripts are written in Ruby
* Support for Java projects
* Support for C++ projects
* Automatic dependency management for C and C++
* Support for maven dependencies
* Advanced project dependencies using normal Ruby method calls
* Support for parallel builds
* Extremly fast (Delta build with 10000 files without changes in less than 1 second)
* Share built files in a cache
* Cross-platform builds on Linux, Mac OS X and Windows


## Installation

* Install needed gem files

    sudo gem install eventmachine em-http-request json sinatra

* Download repository

    git clone https://github.com/wonderix/rmk.git

## C++ Example


    plugin 'gnu' # Load gnu Toolchain
    
    def compile_cpp()
      cc(glob("*.cpp"),[]) # Compile all cpp files in the current directory
    end

You can run this build script with

    rkm.rb compile_cpp

## Java Example

    plugin 'java' # Load java support
    
    def compile_java()
      # compile all files in src/main/java/**/*.java and include them in one jar file named test
      jar("test",javac(glob("src/main/java/**/*.java"),[])) 
    end

You can run this build script with

    rkm.rb compile_java

## Maven support

    plugin 'java'  # Load java support
    plugin 'maven' # Load maven support

    Maven.repository = "http://repo1.maven.org/maven2" # Configure maven repository

    def compile_java()
      # compile all files in src/main/java/**/*.java with tapestry support
      javac(glob("src/main/java/**/*.java"),mvn("org.apache.tapestry","tapestry-core","5.3.6")) 
    end

## Dependency management

You can refer to build results from other directories by loading the project and calling the corresponding method.

    plugin 'java'

    def compile_java()
      # compile all files in src/main/java/**/*.java. Use result from directory ../lib as additional library
      javac(glob("src/main/java/**/*.java"),project("../lib").compile_java)
    end


## Caching

Start cache server

    cache.rb &
    
    == Sinatra/1.4.3 has taken the stage on 4567 for development with backup from Thin
    >> Thin web server (v1.5.1 codename Straight Razor)
    >> Maximum connections set to 1024
    >> Listening on localhost:4567, CTRL+C to stop

        
Run build

    rmk.rb -c http://localhost:4567
    
## Writing plugins

* Put a new file in the plugin directory. The filename should be lower case
* Put a module in this file. The name of the module must match the capitalized filename
* Require your plugin in your build.rmk
* All methods from your plugin are available in your build file

    rmk.rb -c http://localhost:4567
    \# file abc.rb
    module Abc
      def hello()
        puts "Hello"
      end
    end

## Writing work items

* Every build step must be encapsulated in a work item
* All dependency checks are based on work items
* All dependencies must be passed as argument to work_item
* The filenames of the build results of all dependencies are passed as block argument

    \# This method extracts the first 1000 bytes from a given file
    def head(other_work_items)
      \# create new work item and pass all dependencies
      \# when this item needs to be rebuild the given block is called and all 
      \# build results of other_work_items are passed as argument to the block
      work_item(other_work_items) do | other_files |
        result = []
        \# iterate of all files
        other_files.each do | file |
           res = other_files + ".res"
           File.open(res,'wb') { | o | File.open(file,'rb') { | i | i.read(1000) } }
           result << res
        end
        \# return result from block
        result
      end
    end
       
       
     
