module Sumo
	class Server < Aws::ActiveSdb::Base
		set_domain_name :sumo_server

		@@ec2_list = Config.ec2.describe_instances

		def self.search(*names)
			query = names.map { |name| name =~ /(^%)|(%$)/ ? "name like ?" : "name = ?" }.join(" or ")
			results = self.select(:all, :conditions => [ query, *names ])
			names.map do |n|
				results.detect { |r| r.name == n } or abort("No such server '#{n}'")
			end
		end
		
		def name
			state["name"]
		end

		def instance_size
			config["instance_size"]
		end

		def config
			# old_config = [:ami32, :ami64, :instance_size, :availability_zone, :key_name, :security_group, :user, :user_data, :boot_scripts]
			@config ||= Sumo::Config.merged_local_config(name)
		end

		def state
			stringify_keys_and_vals(@attributes)
		end

		def stringify_keys_and_vals(hash)
			hash.inject({}) do |options, (key, value)|
				options[key.to_s] = value.to_s
				options
			end
		end

		## FIXME - how do I handle deleting ip/drives
		def needs_init
			return true if config["elastic_ip"] and not state["elastic_ip"]
			if config["volumes"]
				config["volumes"].each do |volume_config|
					device = volume_config["device"]
					return true if not volumes["device"]
				end
			end
			false
		end

		def init_resources
			if config["volumes"]
				config["volumes"].each do |volume_config|
					device = volume_config["device"]
					size = volume_config["size"]
					if not volumes[device]
						task("Creating EC2 Volume #{device} #{size}") do
							volume_id = Sumo::Config.ec2.create_volume(nil, size, config["availability_zone"])[:aws_id]
							add_volume(volume_id, device)
						end
					else
						puts "Volume #{device} already exists."
					end
				end
			end

			begin
				if config["elastic_ip"] and not state["elastic_ip"]
					task("Adding an elastic ip") { add_ip(Sumo::Config.ec2.allocate_address) }
				else
					puts "Elastic ip #{settings["elastic_ip"]} already exists."
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

#		def method_missing(method, *args)
#			if all_attrs.include?(method)
#				if @attributes[method.to_s]
#					@attributes[method.to_s].first
#				else
#					nil
#				end
#			else
#				super(method, @args)
#			end
#		end

		def update_attributes!(args)
			args.each do |key,value|
				self[key] = value
			end
			save
		end

		def before_create ## FIXME make this work -- also check for validate functions in the api
 #	 	abort("Already a server named #{attrs[:name]}") if Sumo::Server.find_by_name(attrs[:name])
			task("Creating server #{attrs[:name]}") { super(attrs) }
		end

		def self.all
			@@all ||= Server.find(:all)
		end

		def has_ip?
			state["elastic_ip"]
		end

		def has_volumes?
			not volumes.empty?
		end

		def volumes
			Hash[ (@attributes["volumes_flat"] || []).map { |a| a.split(":") } ]
		end

		def destroy
			stop if running?
			task("Deleting Elastic Ip") { Sumo::Config.ec2.release_address(state["elastic_ip"]) } if has_ip?
			volumes.each { |dev,v| remove_volume(v,dev) }
			task("Destroying server #{name}") { super }
			## FIXME - should we delete the server folder and config on disk?
		end

		def ec2_state
			ec2_instance[:aws_state] rescue "offline"
		end

		def ec2_instance
			@@ec2_list.detect { |e| e[:aws_instance_id] == state["instance_id"] } or {}
		end

		def running?
			## other options are "terminated" and "nil"
			["pending", "running", "shutting_down", "degraded"].include?(ec2_state)
		end

		def start
			abort("Already running") if running?
			task("Starting server #{name}")      { launch_ec2 }
			task("Acquire hostname")             { wait_for_hostname }
			task("Wait for ssh")                 { wait_for_ssh }
			task("Attaching ip")                 { attach_ip } if state["elastic_ip"]
			task("Attaching volumes")            { attach_volumes } if has_volumes?
		end

		def restart
			stop
			start
		end

		def stop
			if running?
				instance_id = state["instance_id"]
				task("Terminating instance") { Config.ec2.terminate_instances([ instance_id ]) } 
				update_attributes! :instance_id => nil
				task("Wait for volumes to detach") { wait_for_termination(instance_id) } if volumes.size > 0	
			else
				puts "Server #{name} not running"
			end
		end

		def launch_ec2
			Config.validate ## FIXME

			result = Config.ec2.launch_instances(ami,
				:instance_type => config["instance_size"],
				:availability_zone => config["availability_zone"], ### FIXME
				:key_name => config["key_name"],
				:group_ids => [config["security_group"]],
				:user_data => generate_user_data).first

			update_attributes! :instance_id => result[:aws_instance_id]
		end

		def console_output
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

		def wait_for_termination(instance_id)
			loop do
				ec2 = Config.ec2.describe_instances.detect { |i| i[:aws_instance_id] == instance_id }
				break if ec2[:aws_state] == "terminated"
				sleep 1
			end
		end

		def wait_for_ssh
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
			update_attributes! :elastic_ip => public_ip
			attach_ip
		end

		def attach_ip
			return unless running? and state["elastic_ip"]
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
				Config.ec2.attach_volume(volume_id, state["instance_id"], device)
			end
		end

		def remove_volume(volume_id, device)
			task("Deleting #{device} #{volume_id}") do
				Sumo::Config.ec2.delete_volume(volume_id)
				delete_values( :volumes_flat => "#{device}:#{volume_id}" )
			end
		end

		def add_volume(volume_id, device)
			abort("Server already has a volume on that device") if volumes[device]
			reload
			@attributes["volumes_flat"] = "#{device}:#{volume_id}"
			put
			Config.ec2.attach_volume(volume_id, state["instance_id"], device) if running?
		end

		def connect_ssh
			system "ssh -i #{Sumo::Config.keypair_file} #{config["user"]}@#{hostname}"
		end
		
#		def self.attrs
#			[:ami32, :ami64, :instance_size, :availability_zone, :key_name, :security_group, :user, :user_data, :boot_scripts]
#		end

		def ip
			hostname || config["state_ip"]
		end

		def reload
			@config = nil
			super
		end

		def to_hash
			hash = {}
			Server.attrs.each { |key| hash[key] = self.send(key) }
			hash[:user_data] = generate_user_data
			hash
		end

		def generate_user_data
			return config["user_data"] unless state["boot_scripts"]
			s = "#!/bin/sh\n"
			state["boot_scripts"].split(',').each do |script|
				s += "curl -s \"#{Config.temp_script_url(script)}\" | sh\n"
			end
			s
		end

		def domain?
			name.include? '.'
		end
		
		def create_zerigo_host
			Zerigo::DNS::Base.user = Config.zerigo_user
			Zerigo::DNS::Base.api_key = Config.zerigo_api_key

			# find zone if exists
			zone = host = nil
			Zerigo::DNS::Zone.all().each do |z|
				if z.domain == name
					zone = z
					puts "  Zone #{zone.domain} found with id #{zone.id}."
					break
				end
			end

			if not zone
				begin
					zone = Zerigo::DNS::Zone.create({:domain => name, :ns_type => 'pri_sec'})
					puts "  Zone #{zone.domain} created successfully with id #{zone.id}."
				rescue ResourceParty::ValidationError => e
					puts "  There was an error saving the new zone."
					puts e.message.join(', ')+'.'
				end
			end
			
			if not zone
				puts "ERROR: Could not create Zone for #{name}."
				return
			end
			
			Zerigo::DNS::Host.all(:zone_id=>zone.id).each do |h|
				if h.hostname == nil
					host = h
					break
				end
			end
			
			host_props = {
				:hostname => '',
				:host_type => 'A',
				:data => state["elastic_ip"],
				:zone_id => zone.id
			}
			
			begin
				if host
					host.update(host_props) if host
				else
					host = Zerigo::DNS::Host.create(host_props)
				end
				puts "  Host #{host.hostname} updated with id #{host.id}."
			rescue ResourceParty::ValidationError => e
				puts "  There was an error saving the new host."
				puts e.message.join(', ')+'.'
			end
		end
	end
end
