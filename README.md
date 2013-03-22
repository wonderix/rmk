# rmk

rmk is a translation tool with a mix of features of make, rake maven, Scons and gradle. Unlike these tools rmk follows the idea that translation rules are not configured but implemented like normal code. Make targets become simple method calls. All configuration parameters are passed explicitly.

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
      # compile all files in src/main/java/**/*.java an include them in one jar file named test
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

You can refer to build results from other directories by loading the project an calling the corresponding method.

    plugin 'java'

    def compile_java()
      # compile all files in src/main/java/**/*.java. Use result from directory ../lib as additional library
      javac(glob("src/main/java/**/*.java"),project("../lib").compile_java)
    end
