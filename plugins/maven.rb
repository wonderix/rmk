
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
    end
    
    def end_element(element)
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
        @block.call(@group,@artifact,@version) if @scope == "compile" && !@version.empty?()
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
    @@http ||= Net::HTTP.start(@@repositroy.host,@@repositroy.port)
    request = Net::HTTP::Get.new( "#{@@repositroy.request_uri}/#{artifact}")
    response = @@http.request(request)
    raise "Can't download file #{artifact} form #{@@repositroy}" if response.code.to_i != 200
    File.open(cache,"wb") do | f |
      f.write(response.body)
    end
    cache
  end
  
  def mvn(group_id,artifact_id,version)
    artifact = "#{group_id.tr(".","/")}/#{artifact_id}/#{version}/#{artifact_id}-#{version}"
    result = [ mvn_cache("#{artifact}.jar") ]
    listener = PomListener.new
    listener.callback do |group,artifact,version|
      result.concat(mvn(group,artifact,version))
    end
    parser = XML::SAX::Parser.new(listener)
    parser.parse_file(mvn_cache("#{artifact}.pom"))
    result
  end
  
  def self.repositroy()
    @@repositroy.to_s
  end
  
  def self.repository=(value)
    @@repositroy = URI(value)
  end

end
