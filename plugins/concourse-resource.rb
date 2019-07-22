require 'yaml'
require 'json'
require 'open3'

##################################################################
# Same thing as the resource_types property in your pipeline.yaml
##################################################################

$concourseResourceTypes = Hash.new
class ConcourseResourceType
  attr_reader :definition

  def self.register(definition)
    resourceType = ConcourseResourceType.new(definition)
    name = resourceType.definition["name"]
    $concourseResourceTypes[name] = resourceType
  end

  private
  def initialize(definition)
    @definition = YAML.load(definition)
    # TODO: validate required properties
  end
end


##################################################################
# Same thing as the resources property in your pipeline.yaml
##################################################################

class ConcourseResourceDefinition
  attr_reader :definition

  def initialize(definition)
    @definition = YAML.load(definition)
    # TODO: validate required properties
  end
end


##################################################################
# Concourse build-in Resource Types
##################################################################

ConcourseResourceType.register("
  name: github-release
  type: docker-image
  source:
    repository: concourse/github-release-resource
    tag: latest
")


##################################################################
# Expose Function to rmk
##################################################################

module ConcourseResource

    include Rmk::Tools
  
    def concourse_put(name, resource, put_parameters)
      job(name,[]) do | hidden | 
        resourceType = $concourseResourceTypes[resource.definition["type"]]
        image = resourceType.definition["source"]["repository"] + ":" + resourceType.definition["source"]["tag"]
        mount = "-v #{Dir.pwd}:/mount/"
  
        stdin = Hash.new
        stdin["source"] = resource.definition["source"]
        stdin["params"] = YAML.load(put_parameters)

        command = "docker run #{mount} --rm -i #{image} /opt/resource/out /mount/"
        print command + "\n"
        stdout, stderr, status = Open3.capture3(command, :stdin_data=>stdin.to_json)
        if status.exitstatus != 0
          raise "Could not execute concourse_put:\n#{command}\nstdout:\n#{stdout}\n\nstderr: \n#{stderr}\n"
        end
      end.to_a
    end
end