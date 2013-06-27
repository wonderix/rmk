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
