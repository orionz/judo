module Sumo
	module Config
		extend self

		## FIXME - maybe write these to defaults.json and dont have them hidden here in the code...
		def defaults
			defaults_file = "#{sumo_dir}/defaults.json"
			unless File.exists? defaults_file
				File.open(defaults_file, "w") { |f| f.write(default_config.to_json) }
			end
			JSON.parse File.read(defaults_file)
		end

		def default_config
			{
				:key_name => "sumo",
				:instance_size => "m1.small",
				:ami32 => "ami-bb709dd2",
				:ami64 => "ami-55739e3c",
				:user => "ubuntu",
				:security_group => "sumo",
				:availability_zone => "us-east-1d"  ## FIXME -- this should be state not config -- what if they differ - how to set?
			}
		end

		def merged_config(name)
			stack = load_config_stack(name)
			stack.reverse.inject({}) { |sum,conf| sum.merge(conf) }
		end

		def load_config_stack(name, all = [])
			return (all << defaults) if name.nil?
			conf = read_config(name)
			load_config_stack(conf["import"], all << conf)
		end

		def config_repo
			sumo_config["server_dir"] || sumo_dir
		end

		def server_dirs
			Dir["#{config_repo}/**/config.json"].map { |d| File.dirname(d) }
		end

		def server_dir(name)
			server_dirs.detect { |d| File.basename(d) == name }
		end

		def read_config(name)
			begin
				JSON.parse(File.read("#{server_dir(name)}/config.json"))
			rescue Errno::ENOENT
				{}
			end
		end

		def access_id
			sumo_config["access_id"] || ENV["AWS_ACCESS_KEY_ID"] || (raise "please define access_id in #{sumo_config_file} or in the env as AWS_ACCESS_KEY_ID")
		end
	
		def access_secret
			sumo_config["access_secret"] || ENV["AWS_SECRET_ACCESS_KEY"] || (raise "please define access_secet in #{sumo_config_file} or in the env as AWS_SECRET_ACCESS_KEY")
		end
		
		def ec2
			@ec2 ||= Aws::Ec2.new(access_id, access_secret, :logger => Logger.new(nil))
		end

		def couchdb
			@couchdb ||= CouchRest.database!(couch_url)
		end

		def couch_url
			sumo_config["couch_url"] || "http://127.0.0.1:5984/sumo"
		end

		def keypair_file
			sumo_config["keypair_file"] || "#{sumo_dir}/keypair.pem"
		end

		def connect
			@@con = Aws::ActiveSdb.establish_connection(Config.access_id, Config.access_secret, :logger => Logger.new(nil))
			one_time_setup unless setup?
		end

		## FIXME
		def one_time_setup
			puts "ONE TIME SETUP"
			Sumo::Server.create_domain
		end

		def purge
			## FIXME -- ??
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

		def create_keypair
			## EC2 create_key_pair
			material = ec2.create_key_pair("sumo")[:aws_material]
			File.open(keypair_file, 'w') { |f| f.write material }
			File.chmod 0600, keypair_file
		end

		## FIXME - this seems... lame
		def create_security_group
			## EC2 create_security_group
			ec2.create_security_group('sumo', 'Sumo')
			## EC2 authorize_security_group
			ec2.authorize_security_group_IP_ingress("sumo", 22, 22,'tcp','0.0.0.0/0')
		rescue Aws::AwsError
		end

		private

		def sumo_config
			@config ||= read_sumo_config
		end

		def sumo_config_file
			"#{sumo_dir}/config.yml"
		end

		def sumo_dir(check = Dir.pwd)
			if check == "/"
				if File.exists?("#{ENV['HOME']}/.sumo")
					"#{ENV['HOME']}/.sumo"
				else
					abort "fatal: Not a sumo repository (or any of the parent directories): .sumo"
				end
			end
			@sumo_dir ||= File.exists?(check + "/.sumo") ? check + "/.sumo" : sumo_dir(File.dirname(check))
		end

		def read_sumo_config
			YAML.load File.read(sumo_config_file)
		rescue Errno::ENOENT
			{}
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
