require 'github_api'
require 'time'

module GithubRelease

  class ReleaseSpec
    attr_accessor :tag, :created_at
  end

  class Release
    def initialize(github,org,repo)
      @github = github
      @org = org
      @repo = repo
    end

    def mtime
      Time.parse(result.created_at)
    end

    def result
      @github.repos.releases.latest(@org, @repo).body 
    end

    def to_s
      "Release org:#{@org} repo:#{@repo}"
    end
  end

  def github_release(org,repo)
    github = Github.new do |config|
      yield(config) if block_given?
    end
    [Release.new(github,org,repo)]
  end

end