require_relative '../lib/rmk.rb'

describe File, "#relative_path_from" do
  it "should caclulate correct path" do
    rel  = File.relative_path_from("/home/kramer/sources/eddi/EDDI3/common/","/home/kramer/sources/eddi/EDDI3/PIRcpt")
    rel.should eq("../common")
    rel  = File.relative_path_from("/home/kramer/sources/eddi/EDDI3/","/home/kramer/sources/eddi/EDDI3/PIRcpt")
    rel.should eq("..")
  end
end
