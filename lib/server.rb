module Sumo
	class Server < Aws::ActiveSdb::Base
		set_domain_name :sumo_server

		@@ec2_list = Config.ec2.describe_instances

		def self.search(*names)
			query = names.map { |name| name =~ /(^%)|(%$)/ ? "name like ?" : "name = ?" }.join(" or ")
			results = self.select(:all, :conditions => names.unshift(query))
			raise "No such server" if results.empty?
			results
		end
		
		def self.get_or_create(options)
			server = self.select(:first, :conditions => ["name = ?", options[:name]])
			return server if server
			puts options
			server = Sumo::Server.new :name => options[:name]
			if server.domain?
				options[:elastic_ip] = Sumo::Config.ec2.allocate_address
				server.update_attributes! options
				server.create_zerigo_host
			else
				server.update_attributes! options
			end
			
			return server
		end

		def to_options
			options = {}
			Sumo::Server.attrs.each do |attr|
				options[attr.to_s] = self[attr]
			end
			options
		end

		def cp(new_name, options = {})
			puts self.to_options.merge(options).merge(:name => new_name).inspect
			volumes.each do |dev,vol_id|
			end
			new_server = Sumo::Server.new self.to_options.merge(options).merge(:name => new_name)
			new_server.save
			Sumo::Config.ec2.describe_volumes(volumes.values).each do |aws_vol|
				dev = volumes.invert[aws_vol[:aws_id]]
				size = aws_vol[:aws_size]
				volume_id = Sumo::Config.ec2.create_volume(nil, size, new_server.availability_zone)[:aws_id]
				puts "creating volume #{volume_id} #{dev} #{size}"
				new_server.add_volume(volume_id, dev)
			end unless volumes.empty?
			if has_ip?
				new_server.add_ip(Sumo::Config.ec2.allocate_address)
				puts "allocate ip address #{new_server.elastic_ip}"
			end
		end
		
		def method_missing(method, *args)
			if all_attrs.include?(method)
				if @attributes[method.to_s]
					@attributes[method.to_s].first
				else
					nil
				end
			else
				super(method, @args)
			end
		end

		def update_attributes!(args)
			args.each do |key,value|
				self[key] = value
			end
			save
		end

		def fix
			(JSON.load(volumes_json) rescue {}).each do |device,volume_id|
				reload
				@attributes["volumes_flat"] = "#{device}:#{volume_id}"
				put
			end
		end

		def all_attrs
			[:name, :ami32, :ami64, :instance_size, :instance_id, :state, :availability_zone, :key_name, :security_group, :user, :volumes_flat, :volumes_json, :elastic_ip, :user_data, :boot_scripts]
		end

		def initialize(attrs={})
			super(defaults.merge(uniq_values(attrs)))			
		end
		
		def create(args)
			super
		end

		def defaults
			uniq_values(Config.server_defaults)
		end

		def self.all
			@@all ||= Server.find(:all)
		end

		def self.untracked
			ids = all.map { |a| a.instance_id }
			@@ec2_list.reject { |e| e[:aws_state] == "terminated" or ids.include?(e[:aws_instance_id]) }
		end

		def has_ip?
			elastic_ip
		end

		def has_volumes?
			not volumes.empty?
		end

		def volumes
			Hash[ (@attributes["volumes_flat"] || []).map { |a| a.split(":") } ]
		end

		def destroy
			delete
			volumes.each { |dev,v| Sumo::Config.ec2.delete_volume(v) }
			Sumo::Config.ec2.release_address(elastic_ip) if has_ip?
		end

#		def before_save
#			self["volumes_json"] = volumes.to_json
#		end

		def ec2_state
			ec2_instance[:aws_state] rescue "offline"
		end

		def ec2_instance
			@ec2 ||= Config.ec2.describe_instances([instance_id]).first rescue {}
		end

		def running?
			## other options are "terminated" and "nil"
			["pending", "running", "shutting_down", "degraded"].include?(ec2_state)
		end

		def start
			Config.validate ## FIXME

			result = Config.ec2.launch_instances(ami,
				:instance_type => instance_size,
				:availability_zone => availability_zone,
				:key_name => key_name,
				:group_ids => [security_group],
				:user_data => generate_user_data).first

			update_attributes! :instance_id => result[:aws_instance_id]
		end

		def launch
			start
			wait_for_hostname
			wait_for_ssh
			attach_ip
			attach_volumes
		end

		def terminate
			Config.ec2.terminate_instances([ instance_id ])
			wait_for_termination if volumes.size > 0
			update_attributes! :instance_id => nil
			"#{instance_id} scheduled for termination"
		end

		def console_output
			Config.ec2.get_console_output(instance_id)[:aws_output]
		end

		def ami
			ia32? ? ami32 : ami64
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
				refresh
				return hostname if hostname
				sleep 1
			end
		end

		def wait_for_termination
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
			return unless running? and elastic_ip
			Config.ec2.associate_address(instance_id, elastic_ip)
			refresh
		end
		
		def dns_name
			return nil unless self[:elastic_ip]
			`dig +short -x #{self[:elastic_ip]}`.strip
		end

		def attach_volumes
			return unless running?
			volumes.each do |device,volume_id|
				Config.ec2.attach_volume(volume_id, instance_id, device)
			end
		end

		def add_volume(volume_id, device)
			abort("Server already has a volume on that device") if volumes[device]
			## TODO make sure its not attached to someone else
			## delete_values( :volumes_flat => "#{device}:#{volume_id}" ) ## to remove
			reload
			@attributes["volumes_flat"] = "#{device}:#{volume_id}"
			put
			Config.ec2.attach_volume(volume_id, instance_id, device) if running?
		end

		def connect_ssh
			system "ssh -i #{Sumo::Config.keypair_file} #{user}@#{hostname}"
		end
		
		def self.attrs
			[:ami32, :ami64, :instance_size, :availability_zone, :key_name, :security_group, :user, :user_data, :boot_scripts]
		end

		def refresh
			@ec2 = nil
			@volumes = nil
			reload
		end

		def to_hash
			hash = {}
			Server.attrs.each { |key| hash[key] = self.send(key) }
			hash[:user_data] = generate_user_data
			hash
		end

		def duplicate(new_name="#{name}-copy")
			params = { :name => new_name }
			attributes.each do |key, value|
				params[key.to_sym] = value if self.class.attrs.include? key.to_sym
			end
			self.class.new params
		end

		def generate_user_data
			return user_data unless boot_scripts
			s = "#!/bin/sh\n"
			boot_scripts.split(',').each do |script|
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
				:data => elastic_ip,
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
