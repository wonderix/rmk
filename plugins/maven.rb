
require 'rubygems'
require 'net/http'
require 'fileutils'
require 'nokogiri'

module Maven

  include Nokogiri


  class PomListener < XML::SAX::Document
    def initilize()
     reset()
    end
    
    def callback(&block)
      @block = block
      @stack = []
    end
    
    def reset()
      @current = ""
      @group = ""
      @artifact = ""
      @version = ""
      @scope = "compile"
    end
    
    def start_element(element, attributes)
      @current = ""
      @stack.push(element)
    end
    
    def end_element(element)
      @stack.pop
      case element
      when "groupId"
        @group = @current
      when "artifactId"
        @artifact = @current
      when "version"
        @version = @current
      when "scope"
        @scope = @current
      when "dependency"
        @block.call(@group,@artifact,@version) if @scope == "compile"  && !@version.empty?() && @version[0] != ?$ && @stack[-1] == "dependencies" && @stack[-2] == "project"
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
    artifact = "#{group_id.tr(".","/")}/#{artifact_id}/#{version}/#{artifact_id}-#{version}"
    begin
      result = [ mvn_cache("#{artifact}.jar") ]
      listener = PomListener.new
      listener.callback do |group,art,vers|
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

if __FILE__ == $0
  listener = Maven::PomListener.new
  listener.callback do |group,artifact,version|
    puts("  mvn('#{group}','#{artifact}','#{version}')")
  end
  parser = Nokogiri::XML::SAX::Parser.new(listener)
  parser.parse_file("pom.xml")
end