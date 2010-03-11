### NEEDED for new gem launch

### 32 hrs to go - 12:00am Feb 26th - expected completion Mar 2
### [X] judo init (2 hrs)
### [X] implement real default config - remove special case code (3 hrs)
### [X] refactor keypair.pem setup (3 hrs)
### [X] version in the db - require upgrade of gem if db version ahead (1 hr)
### [X] implement multiple security groups (1 hr)
### [-] complete slug compile - load into s3 (4 hrs)
###     [X] compile and put in s3
###     [X] attach and increment version number
###     [X] list version number on "judo list"
###     [X] update kuzushi to pull down a compiled tar.gz
###     [X] error if version is blank
### [ ] two phase delete (1 hr)
### [-] refactor availability_zone (2 hrs)
###     [ ] pick availability zone from config "X":"Y" or  "X":["Y","Z"]
###     [ ] assign to state on creation ( could delay till volume creation )
### [ ] implement auto security_group creation and setup (6 hrs)
### [ ] write some examples - simple postgres/redis/couchdb server (5hrs)
### [ ] write new README (4 hrs)
### [ ] realase new gem! (1 hr)

### [ ] user a logger service (1 hr)
### [ ] write specs (5 hr)

### Error Handling
### [ ] no availability zone before making disks
### [ ] security group does not exists

### Do Later
### [ ] use amazon's new conditional write tools so we never have problems from concurrent updates
### [ ] is thor really what we want to use here?
### [ ] need to be able to pin a config to a version of kuzushi - gem updates can/will break a lot of things
### [ ] I want a "judo monitor" command that will make start servers if they go down, and poke a listed port to make sure a service is listening, would be cool if it also detects wrong ami, wrong secuirity group, missing/extra volumes, missing/extra elastic_ip - might not want to force a reboot quite yet in these cases
### [ ] Implement "judo snapshot [NAME]" to take a snapshot of the ebs's blocks
### [ ] ruby 1.9.1 support
### [ ] find a good way to set the hostname or prompt to :name
### [ ] remove fog/s3 dependancy
### [ ] enforce template files end in .erb to make room for other possible templates as defined by the extensions
### [ ] zerigo integration for automatic DNS setup
### [ ] How cool would it be if this was all reimplemented in eventmachine and could start lots of boxes in parallel?  Would need to evented AWS api calls... Never seen a library to do that - would have to write our own... "Fog Machine?"

module Judo
	class Server
		attr_accessor :name, :group

		def initialize(name, group)
			@name = name
			@group = group
		end

		def domain
			"judo_servers"
		end

		def sdb
			Judo::Config.sdb
		end

		def fetch_state
			Judo::Config.sdb.get_attributes(domain, name)[:attributes]
		end

		def super_state
			@@state ||= {}
		end

		def state
			super_state[name] ||= fetch_state
		end

		def get(key)
			state[key] && [state[key]].flatten.first
		end

		def instance_id
			get "instance_id"
		end

		def elastic_ip
			get "elastic_ip"
		end

		def version_desc
			return "" unless running?
			if version == group.version
				"v#{version}"
			else
				"v#{version}/#{group.version}"
			end
		end

		def version
			get("version").to_i
		end

		def virgin?
			get("virgin").to_s == "true"  ## I'm going to set it to true and it will come back from the db as "true" -> could be "false" or false or nil also
		end

		def secret
			get "secret"
		end

		def volumes
			Hash[ (state["volumes"] || []).map { |a| a.split(":") } ]
		end

		def update(attrs)
			sdb.put_attributes(domain, name, attrs, :replace)
			state.merge! attrs
		end

		def add(key, value)
			sdb.put_attributes(domain, name, { key => value })
			(state[key] ||= []) << value
		end

		def remove(key, value = nil)
			if value
				sdb.delete_attributes(domain, name, key => value)
				state[key] - [value]
			else
				sdb.delete_attributes(domain, name, [ key ])
				state.delete(key)
			end
		end

		def delete
			group.delete_server(self)
			sdb.delete_attributes(domain, name)
		end

######## end simple DB access  #######

		def instance_size
			config["instance_size"]
		end

		def config
			group.config
		end

		def to_s
			"#{group}:#{name}"
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
								volume_id = Judo::Config.ec2.create_volume(nil, size, config["availability_zone"])[:aws_id]
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
				if config["elastic_ip"] and not elastic_ip
					### EC2 allocate_address
					task("Adding an elastic ip") do
						ip = Judo::Config.ec2.allocate_address
						add_ip(ip)
					end
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

		def has_ip?
			!!elastic_ip
		end

		def has_volumes?
			not volumes.empty?
		end

		def ec2_volumes
			return [] if volumes.empty?
			Judo::Config.ec2.describe_volumes( volumes.values )
		end

		def remove_ip
			Judo::Config.ec2.release_address(elastic_ip) rescue nil
			remove "elastic_ip"
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
			@@ec2_list.detect { |e| e[:aws_instance_id] == instance_id } or {}
		end

		def running?
			## other options are "terminated" and "nil"
			["pending", "running", "shutting_down", "degraded"].include?(ec2_state)
		end

		def start
			abort "Already running" if running?
			abort "No config has been commited yet, type 'judo commit'" unless group.version > 0
			task("Starting server #{name}")      { launch_ec2 }
			task("Acquire hostname")             { wait_for_hostname }
			task("Wait for ssh")                 { wait_for_ssh }
			task("Attaching ip")                 { attach_ip } if elastic_ip
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
			task("Terminating instance") { Config.ec2.terminate_instances([ instance_id ]) }
			task("Wait for volumes to detach") { wait_for_volumes_detached } if volumes.size > 0
			remove "instance_id"
		end

		def launch_ec2
#			validate

			## EC2 launch_instances
			result = Config.ec2.launch_instances(ami,
				:instance_type => config["instance_size"],
				:availability_zone => config["availability_zone"],
				:key_name => config["key_name"],
				:group_ids => security_groups,
				:user_data => user_data).first

			update "instance_id" => result[:aws_instance_id], "virgin" => false, "version" => group.version
		end

		def security_groups
			[ config["security_group"] ].flatten
		end

		def console_output
			abort "not running" unless running?
			Config.ec2.get_console_output(instance_id)[:aws_output]
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

		def add_ip(public_ip)
			update "elastic_ip" => public_ip
			attach_ip
		end

		def attach_ip
			return unless running? and elastic_ip
			### EC2 associate_address
			Config.ec2.associate_address(instance_id, elastic_ip)
		end
		
		def dns_name
			return nil unless elastic_ip
			`dig +short -x #{elastic_ip}`.strip
		end

		def attach_volumes
			return unless running?
			volumes.each do |device,volume_id|
				### EC2 attach_volume
				Config.ec2.attach_volume(volume_id, instance_id, device)
			end
		end

		def remove_volume(volume_id, device)
			task("Deleting #{device} #{volume_id}") do
				### EC2 delete_volume
				Judo::Config.ec2.delete_volume(volume_id)
				remove "volumes", "#{device}:#{volume_id}"
			end
		end

		def add_volume(volume_id, device)
			abort("Server already has a volume on that device") if volumes[device]

			add "volumes", "#{device}:#{volume_id}"

			Config.ec2.attach_volume(volume_id, instance_id, device) if running?

			volume_id
		end

		def connect_ssh
			abort "not running" unless running?
			system "chmod 600 #{group.keypair_file}"
			system "ssh -i #{group.keypair_file} #{config["user"]}@#{hostname}"
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
			super_state.delete(name)
		end

		def user_data
			<<USER_DATA
#!/bin/sh

export DEBIAN_FRONTEND="noninteractive"
export DEBIAN_PRIORITY="critical"
export SECRET='#{secret}'
apt-get update
apt-get install ruby rubygems ruby-dev irb libopenssl-ruby libreadline-ruby -y
gem install kuzushi --no-rdoc --no-ri
GEM_BIN=`ruby -r rubygems -e "puts Gem.bindir"`
echo "$GEM_BIN/kuzushi #{virgin? && "init" || "start"} '#{url}'" > /var/log/kuzushi.log
$GEM_BIN/kuzushi #{virgin? && "init" || "start"} '#{url}' >> /var/log/kuzushi.log 2>&1
USER_DATA
		end

		def url
			@url ||= group.s3_url
		end

		def validate
			### EC2 create_security_group
			Judo::Config.create_security_group

			### EC2 desctibe_key_pairs
			k = Judo::Config.ec2.describe_key_pairs.detect { |kp| kp[:aws_key_name] == config["key_name"] }

			if k.nil?
				if config["key_name"] == "judo"
					Judo::Config.create_keypair
				else
					raise "cannot use key_pair #{config["key_name"]} b/c it does not exist"
				end
			end
		end
		
	end
end
