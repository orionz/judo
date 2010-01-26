require File.dirname(__FILE__) + '/base'

describe Sumo::Server do
	before do
		# configure AWS stubs
		Sumo::Config.ec2.stubs(:allocate_address).returns('192.168.2.2')
		Sumo::Server.stubs(:select).returns(nil)
		@server = Sumo::Server.get_or_create('example.com')
	end
	
	it "creates a new server" do
		server = Sumo::Server.get_or_create('example')
		server.name.should == 'example'
		server.elastic_ip.should == nil
	end
	
	it "creates a new domain" do
		server = Sumo::Server.get_or_create('example.com')
		server.name.should == 'example.com'
		server.elastic_ip.should == '192.168.2.2'
	end
	
	##
	
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
