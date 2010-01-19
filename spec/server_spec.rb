require File.dirname(__FILE__) + '/base'

describe Sumo::Server do
	it "defaults to user ubuntu if none is specified in the config" do
		sumo = Sumo::Server.new :name => "test"
		sumo.user.should == 'ubuntu'
	end

	it "defaults to user can be overwritten on new" do
		sumo = Sumo::Server.new :name => "test", :user => "root"
		sumo.user.should == 'root'
	end

	it "duplicates an existing server" do
		original = Sumo::Server.new(:name => 'test', :ami32 => 'abc')
		dupe = original.duplicate
		dupe.class.should == Sumo::Server
		dupe.name.should == 'test-copy'
		dupe.ami32.should == 'abc'
	end
end
