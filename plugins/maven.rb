
require 'rubygems'
require 'net/http'
require 'fileutils'
require 'nokogiri'

module Maven

  include Nokogiri


  class MetadataListener < XML::SAX::Document
  
    attr_reader :version
    def initialize()
      @version = ""
      @stack = []
    end
    def start_element(element, attributes)
      @stack.push(element)
    end
    def end_element(element)
      @stack.pop
    end
    def characters(text)
      @version = text if @stack == %w(metadata versioning snapshotVersions snapshotVersion value)
    end
  end

  class PomListener < XML::SAX::Document
    attr_accessor :skip_invalid_version
    def initialize()
     reset()
     @skip_invalid_version = true
    end
    
    def dependency_callback(&block)
      @dependency_callback = block
      @stack = []
    end
    
    def reset()
      @current = ""
      @group = ""
      @artifact = ""
      @version = ""
      @scope = "compile"
      @optional = ""
    end
    
    def start_element(element, attributes)
      @current = ""
      @stack.push(element)
    end
    
    def end_element(element)
      @stack.pop
      if @stack == %w(project dependencies dependency) 
        case element
        when "groupId"
          @group = @current
        when "artifactId"
          @artifact = @current
        when "version"
          @version = @current
        when "scope"
          @scope = @current
        when "optional"
          @optional = @current
        end
      elsif @stack == %w(project dependencies) && element == "dependency"
        @dependency_callback.call(@group,@artifact,@version) if @scope == "compile"  && ( !@skip_invalid_version || (!@version.empty?() && @version[0] != ?$)) && @optional != "true"
        reset()
      end
      @current = ""
    end
    def characters(text)
      @current += text
    end
  end
  
  def mvn_cache(artifact)
    cache = "#{ENV['HOME']}/.m2/repository/#{artifact}"
    return cache if File.readable?(cache)
    FileUtils.mkdir_p(File.dirname(cache))
    begin
      @@http ||= Net::HTTP.start(@@repositroy.host,@@repositroy.port)
      request = Net::HTTP::Get.new( "#{@@repositroy.request_uri}/#{artifact}")
      response = @@http.request(request)
      raise "HTTP status \"#{response.code}\"" if response.code.to_i != 200
      File.open(cache,"wb") do | f |
        f.write(response.body)
      end
      cache
    rescue Exception => exc
      raise "Can't download artifact \"#{artifact}\" form #{@@repositroy}: #{exc.message}"
    end
  end
  
  def mvn(group_id,artifact_id,version)
    artifact_dir = "#{group_id.tr(".","/")}/#{artifact_id}/#{version}"
      
    begin
      if version[-8,8] == "SNAPSHOT"
        listener = MetadataListener.new
        parser = XML::SAX::Parser.new(listener)
        parser.parse_file(mvn_cache("#{artifact_dir}/maven-metadata.xml"))
      end
      artifact = "#{artifact_dir}/#{artifact_id}-#{version}"
      result = [ mvn_cache("#{artifact}.jar") ]
      listener = PomListener.new
      listener.dependency_callback do |group,art,vers|
        result.concat(mvn(group,art,vers))
      end
      parser = XML::SAX::Parser.new(listener)
      parser.parse_file(mvn_cache("#{artifact}.pom"))
      result
    rescue Exception => exc
      raise "Can't download dependencies of \"#{artifact}\" : #{exc.message}"
    end
  end
  
  def self.repositroy()
    @@repositroy.to_s
  end
  
  def self.repository=(value)
    @@repositroy = URI(value)
  end

end

# Used to convert pom to rmk
if __FILE__ == $0
  listener = Maven::PomListener.new
  listener.skip_invalid_version = false
  listener.dependency_callback do |group,artifact,version|
    puts("  mvn('#{group}','#{artifact}','#{version}')")
  end
  parser = Nokogiri::XML::SAX::Parser.new(listener)
  parser.parse_file("pom.xml")
end
