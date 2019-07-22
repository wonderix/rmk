
require_relative '../lib/rmk.rb'
require_relative '../plugins/github-release.rb'

include GithubRelease

describe GithubRelease do

  around(:each) do |example|
    EventMachine.run do
      Fiber.new do
        example.run
        EventMachine.stop
      end.resume
    end
  end

  it 'returns last release' do
    release = github_release('istio','istio') 
    expect(release[0].result.tag_name).to match(/\d+\.\d+\.\d+/)
  end
end
