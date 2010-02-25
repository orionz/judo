## TODO

### Do now
### (*) fix simpledb - make sure its reliable
### (*) Need to figure out availability_zone -> maybe config lists which ones to choose but state holds the the chosen one
### (*) need to flesh out the idea of the default config - should be able to have sumo 1.0 ease of use with this!
### (*) should be able to specify security group rules in here - and have the security group configured on boot - no more special sumo config - just throw it in the default
### (*) need to figure out a smart workflow for keypair.pem - might not be needed with kuzushi...
### (*) enforce template files end in .erb to make room for other possible templates as defined by the extensions
### (*) would be nice to have a two phase delete "sumo destroy; sumo trash:list; sumo trash:undelete; sumo trash:empty" - prevent mishaps

### Do Later
### (3) need to be able to pin a config to a version of kuzushi - gem updates can/will break a lot of things
### (6) sumo commit is really just pushing a filesystem - there's a better way to do this - git?? - compile a slug?
### --
### (8) I want a "sumo monitor" command that will make start servers if they go down, and poke a listed port to make sure a service is listening, would be cool if it also detects wrong ami, wrong secuirity group, missing/extra volumes, missing/extra elastic_ip - might not want to force a reboot quite yet in these cases
### (9) How cool would it be if this was all reimplemented in eventmachine and could start lots of boxes in parallel?  Would need to evented AWS api calls... Never seen a library to do that - would have to write our own... "Fog Machine?"
### (11) Should be outputting to a logger service - just have command line tool configure stdout as the logger
### --
### (14) Implement "sumo snapshot [NAME]" to take a snapshot of the ebs's blocks
### (15) ruby 1.9.1 support
### (16) find a good way to set the hostname or prompt to :name

module Sumo
	class Server < Aws::ActiveSdb::Base
		set_domain_name :sumo_server

		def self.search(group, *names)
			query = "group = ?"
			results = self.select(:all, :conditions => [ query, group])
			results = results.select { |r| names.include?(r.name) } unless names.empty?
			names.map do |n|
				results.detect { |r| r.name == n } or abort("No such server '#{n}'")
			end
			results
		end
		
		def group
			state["group"] || "default"
		end

		def name
			state["name"]
		end

		def instance_size
			config["instance_size"]
		end

		def config
			@config ||= Sumo::Config.merged_config(group)
		end

		def state
			stringify_keys_and_vals(@attributes)
		end

		def to_s
			"#{group}:#{name}"
		end

		def stringify_keys_and_vals(hash)
			hash.inject({}) do |options, (key, value)|
				options[key.to_s] = value.to_s
				options
			end
		end

		def allocate_resources
			if config["volumes"]
				config["volumes"].each do |volume_config|
					device = volume_config["device"]
					if volume_config["media"] == "ebs"
						size = volume_config["size"]
						if not volumes[device]
							task("Creating EC2 Volume #{device} #{size}") do
								### EC2 create_volume
								volume_id = Sumo::Config.ec2.create_volume(nil, size, config["availability_zone"])[:aws_id]
								add_volume(volume_id, device)
							end
						else
							puts "Volume #{device} already exists."
						end
					else
						puts "device #{device || volume_config["mount"]} is not of media type 'ebs', skipping..."
					end
				end
			end

			begin
				if config["elastic_ip"] and not state["elastic_ip"]
					### EC2 allocate_address
					task("Adding an elastic ip") { add_ip(Sumo::Config.ec2.allocate_address) }
				end
			rescue Aws::AwsError => e
				if e.message =~ /AddressLimitExceeded/
					abort "Failed to allocate ip address: Limit Exceeded"
				else
					raise
				end
			end
		end

		def task(msg, &block)
			self.class.task(msg, &block)
		end

		def self.task(msg, &block)
			printf "---> %-24s ", "#{msg}..."
			STDOUT.flush
			start = Time.now
			result = block.call
			result = "done" unless result.is_a? String
			finish = Time.now
			time = sprintf("%0.1f", finish - start)
			puts "#{result} (#{time}s)"
			result
		end

		def update_attributes!(args)
			args.each do |key,value|
				self[key] = value
			end
			save
		end

		def self.create(attrs)
			abort("Server needs a name") if attrs[:name].nil?
			abort("Already a server named #{attrs[:name]}") if Sumo::Server.find_by_name(attrs[:name])
			Sumo::Config.read_config(attrs[:group]) ## make sure the config is valid
			task("Creating server #{attrs[:name]}") { }
			super(attrs.merge(:virgin => true, :secret => rand(2 ** 128).to_s(36)))
		end

		def self.all
			@@all ||= Server.find(:all)
		end

		def self.all_group(group)
			Server.find_all_by_group(group)
		end

		def has_ip?
			!!state["elastic_ip"]
		end

		def has_volumes?
			not volumes.empty?
		end

		def ec2_volumes
			return [] if volumes.empty?
			Sumo::Config.ec2.describe_volumes( volumes.values )
		end

		def volumes
			Hash[ (@attributes["volumes_flat"] || []).map { |a| a.split(":") } ]
		end

		def remove_ip
			Sumo::Config.ec2.release_address(state["elastic_ip"]) rescue nil
			update_attributes! :elastic_ip => nil
		end

		def destroy
			stop if running?
			### EC2 release_address
			task("Deleting Elastic Ip") { remove_ip } if has_ip?
			volumes.each { |dev,v| remove_volume(v,dev) }
			task("Destroying server #{name}") { delete }
		end

		def ec2_state
			ec2_instance[:aws_state] rescue "offline"
		end

		def ec2_instance
			### EC2 describe_instances
			@@ec2_list ||= Config.ec2.describe_instances
			@@ec2_list.detect { |e| e[:aws_instance_id] == state["instance_id"] } or {}
		end

		def running?
			## other options are "terminated" and "nil"
			["pending", "running", "shutting_down", "degraded"].include?(ec2_state)
		end

		def start
			abort "Already running" if running?
			task("Starting server #{name}")      { launch_ec2 }
			task("Acquire hostname")             { wait_for_hostname }
			task("Wait for ssh")                 { wait_for_ssh }
			task("Attaching ip")                 { attach_ip } if state["elastic_ip"]
			task("Attaching volumes")            { attach_volumes } if has_volumes?
		end

		def restart
			stop if running?
			start
		end

		def generic_name?
			name =~ /^#{group}[.]\d*$/
		end

		def generic?
			volumes.empty? and not has_ip? and generic_name?
		end

		def stop
			abort "not running" unless running?
			## EC2 terminate_isntaces
			task("Terminating instance") { Config.ec2.terminate_instances([ state["instance_id"] ]) }
			task("Wait for volumes to detach") { wait_for_volumes_detached } if volumes.size > 0
			update_attributes! :instance_id => nil
			reload
		end

		def launch_ec2
			validate

			## EC2 launch_instances
			result = Config.ec2.launch_instances(ami,
				:instance_type => config["instance_size"],
				:availability_zone => config["availability_zone"],
				:key_name => config["key_name"],
				:group_ids => [config["security_group"]],
				:user_data => user_data).first

			## can find : :aws_availability_zone
			update_attributes! :instance_id => result[:aws_instance_id], :virgin => nil
		end

		def console_output
			### EC2 get_console_output
			Config.ec2.get_console_output(state["instance_id"])[:aws_output]
		end

		def ami
			ia32? ? config["ami32"] : config["ami64"]
		end

		def ia32?
			["m1.small", "c1.medium"].include?(instance_size)
		end

		def ia64?
			not ia32?
		end

		def hostname
			ec2_instance[:dns_name] == "" ? nil : ec2_instance[:dns_name]
		end

		def wait_for_hostname
			loop do
				reload
				return hostname if hostname
				sleep 1
			end
		end

		def wait_for_volumes_detached
			loop do
				break if ec2_volumes.reject { |v| v[:aws_status] == "available" }.empty?
				sleep 2
			end
		end

		def wait_for_termination
			loop do
				reload
				break if ec2_instance[:aws_state] == "terminated"
				sleep 1
			end
		end

		def wait_for_ssh
			abort "not running" unless running?
			loop do
				begin
					Timeout::timeout(4) do
						TCPSocket.new(hostname, 22)
						return
					end
				rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
				end
			end
		end

		def ssh(cmds)
			IO.popen("ssh -i #{Config.keypair_file} #{user}@#{hostname} > ~/.sumo/ssh.log 2>&1", "w") do |pipe|
				pipe.puts cmds.join(' && ')
			end
			unless $?.success?
				abort "failed\nCheck ~/.sumo/ssh.log for the output"
			end
		end

		def add_ip(public_ip)
			## TODO - make sure its not in use
			reload
			update_attributes! :elastic_ip => public_ip
			attach_ip
		end

		def attach_ip
			return unless running? and state["elastic_ip"]
			### EC2 associate_address
			Config.ec2.associate_address(state["instance_id"], state["elastic_ip"])
			reload
		end
		
		def dns_name
			return nil unless state["elastic_ip"]
			`dig +short -x #{state["elastic_ip"]}`.strip
		end

		def attach_volumes
			return unless running?
			volumes.each do |device,volume_id|
				### EC2 attach_volume
				Config.ec2.attach_volume(volume_id, state["instance_id"], device)
			end
		end

		def remove_volume(volume_id, device)
			task("Deleting #{device} #{volume_id}") do
				### EC2 delete_volume
				Sumo::Config.ec2.delete_volume(volume_id)
				delete_values( :volumes_flat => "#{device}:#{volume_id}" )
			end
		end

		def add_volume(volume_id, device)
			abort("Server already has a volume on that device") if volumes[device]
			reload  ## important to try and minimize race conditions with other potential clients
			@attributes["volumes_flat"] = "#{device}:#{volume_id}"
			put
			reload ## important so we don't overwrite volumes_flat later
			### EC2 attach_volume
			Config.ec2.attach_volume(volume_id, state["instance_id"], device) if running?
			volume_id
		end

		def connect_ssh
			abort "not running" unless running?
			system "ssh -i #{Sumo::Config.keypair_file} #{config["user"]}@#{hostname}"
		end
		
		def self.commit
			Config.group_dirs.each do |group_dir|
				group = File.basename(group_dir)
				next if Config.group and Config.group != group
				puts "commiting #{group}"
				doc = Config.couchdb.get(group) rescue {}
				config = Config.read_config(group)
				config['_id'] = group
				config['_rev'] = doc['_rev'] if doc.has_key?('_rev')
				response = Config.couchdb.save_doc(config)
				doc = Config.couchdb.get(response['id'])

				# walk subdirs and save as _attachments
				['files', 'templates', 'packages', 'scripts'].each { |subdir|
					Dir["#{group_dir}/#{subdir}/*"].each do |f|
						puts "storing attachment #{f}"
						doc.put_attachment("#{subdir}/#{File.basename(f)}", File.read(f))
					end
				}
			end
		end

		def ip
			hostname || config["state_ip"]
		end

		def reload
			@@ec2_list = nil
#			@config = nil
			super
		end

		def user_data
			<<USER_DATA
#!/bin/sh

export DEBIAN_FRONTEND="noninteractive"
export DEBIAN_PRIORITY="critical"
export SECRET='#{state["secret"]}'
apt-get update
apt-get install ruby rubygems ruby-dev irb libopenssl-ruby libreadline-ruby -y
gem install kuzushi --no-rdoc --no-ri
GEM_BIN=`ruby -r rubygems -e "puts Gem.bindir"`
$GEM_BIN/kuzushi #{state["virgin"] ? "init" : "start"} #{url}
USER_DATA
		end

		def url
			"#{Sumo::Config.couch_url}/#{group}"
		end

		def validate
			### EC2 create_security_group
			Sumo::Config.create_security_group

			### EC2 desctibe_key_pairs
			k = Sumo::Config.ec2.describe_key_pairs.detect { |kp| kp[:aws_key_name] == config["key_name"] }

			if k.nil?
				if config["key_name"] == "sumo"
					Sumo::Config.create_keypair
				else
					raise "cannot use key_pair #{config["key_name"]} b/c it does not exist"
				end
			end
		end
		
	end
end
