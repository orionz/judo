module Sumo
	module Config
		extend self

		def server_defaults
			{
				:key_name => key_name,
				:instance_size => instance_size,
				:ami32 => ami32,
				:ami64 => ami64,
				:user => user,
				:security_group => security_group,
				:availability_zone => availability_zone  ## FIXME
			}
		end

		def merged_local_config(name)
			configs = load_local_config(name)
			configs.reverse.inject({}) { |sum,conf| sum.merge(conf) }
		end

		def load_local_config(name, all = [])
			return (all << JSON.parse(server_defaults.to_json)) if name.nil?
			conf = read_local_config(name)
			load_local_config(conf["import"], all << conf)
		end

		def server_dir
			config["server_dir"] || sumo_dir
		end

		def read_local_config(name)
			begin
				JSON.parse(File.read(server_dir + "/" + name + "/config.json"))
			rescue Errno::ENOENT
#				puts "Warning: no config file for #{name} in #{server_dir}"
				{}
			end
		end

		def security_group
			config["security_group"] || "sumo"
		end

		def user
			config["user"] || "ubuntu"
		end

		def ia32?
			["m1.small", "c1.medium"].include?(instance_size)
		end

		def ia64?
			not ia32?
		end

		def ami32
			config["ami32"] || "ami-bb709dd2" ## default to ubuntu 9.10 server
		end

		def ami64
			config["ami64"] || "ami-55739e3c" ## default to ubuntu 9.10 server
		end

		def availability_zone
			config['availability_zone'] || 'us-east-1d'
		end

		def instance_size
			config['instance_size'] || 'm1.small'
		end

		def access_id
			config["access_id"] || ENV["AWS_ACCESS_KEY_ID"] || (raise "please define access_id in #{sumo_config_file} or in the env as AWS_ACCESS_KEY_ID")
		end
	
		def access_secret
			config["access_secret"] || ENV["AWS_SECRET_ACCESS_KEY"] || (raise "please define access_secet in #{sumo_config_file} or in the env as AWS_SECRET_ACCESS_KEY")
		end
		
		def zerigo_user
			config["zerigo_user"] || ENV["ZERIGO_USER"] || (raise "please define zerigo_user in #{sumo_config_file} or in the env as ZERIGO_USER")
		end
		
		def zerigo_api_key
			config["zerigo_api_key"] || ENV["ZERIGO_API_KEY"] || (raise "please define zerigo_api_key in #{sumo_config_file} or in the env as ZERIGO_API_KEY")
		end

		def ec2
			@ec2 ||= Aws::Ec2.new(access_id, access_secret, :logger => Logger.new(nil))
		end

		def key_name
			config["key_name"] || "sumo"
		end

		def keypair_file
			config["keypair_file"] || "#{sumo_dir}/keypair.pem"
		end

		def validate
			create_security_group

			k = ec2.describe_key_pairs.detect { |kp| kp[:aws_key_name] == key_name }

			if k.nil? 
				if key_name == "sumo"
					create_keypair  ## FIXME - do not create if it exists - tell the user to download and it and put it int the .sumo dir
				else
					raise "cannot use key_pair #{key_name} b/c it does not exist"
				end
			end
		end

		def connect
			@@con = Aws::ActiveSdb.establish_connection(Config.access_id, Config.access_secret, :logger => Logger.new(nil))
			one_time_setup unless setup?
		end

		def one_time_setup
			puts "ONE TIME SETUP"
			Sumo::Server.create_domain
		end

		def purge
			puts "PURGE"
			Sumo::Server.delete_domain
		end

		def setup?
			Sumo::Server.connection.list_domains[:domains].include? Sumo::Server.domain
		end
		
		def upload_script(filename)
			scripts_bucket.put(File.basename(filename), File.new(filename,"r").read)
		end
		
		def list_scripts
			scripts_bucket.keys.each do |k|
				puts k, self.temp_script_url(k.to_s)
			end
		end

		def self.temp_script_url(key, expires=300)
			scripts_bucket.s3.interface.get_link(scripts_bucket.to_s, key, Time.now.to_i + expires)
		end

		private

		def config
			@config ||= read_config
		end

		def sumo_config_file
			"#{sumo_dir}/config.yml"
		end

		def sumo_dir
			## FIXME -- I would love it if we could look for a sumo.yml in the ../../../../ by default - then look in HOME/.sumo next
			## this way we could have our servers and .gitignore sumo.yml and have different clouds in different dirs with different credentials...
			"#{ENV['HOME']}/.sumo"
		end

		def read_config
			YAML.load File.read(sumo_config_file)
		rescue Errno::ENOENT
			{}
		end

		def create_keypair
			material = ec2.create_key_pair("sumo")[:aws_material]
			File.open(keypair_file, 'w') { |f| f.write material }
			File.chmod 0600, keypair_file
		end

		def create_security_group
			ec2.create_security_group('sumo', 'Sumo')
			ec2.authorize_security_group_IP_ingress("sumo", 22, 22,'tcp','0.0.0.0/0')
		rescue Aws::AwsError
		end
		
		def s3
			@s3 ||= RightAws::S3.new(access_id, access_secret, :logger => Logger.new(nil))
		end
		
		def scripts_bucket
			name = access_id # is this a bad idea for some reason?
			@scripts_bucket ||= s3.bucket(name, true)
		end
	end
end
