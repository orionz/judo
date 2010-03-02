module Judo
	module Config
		extend self

		## FIXME - maybe write these to defaults.json and dont have them hidden here in the code...
		def defaults
			defaults_file = "#{judo_dir}/defaults.json"
			unless File.exists? defaults_file
				File.open(defaults_file, "w") { |f| f.write(default_config.to_json) }
			end
			JSON.parse File.read(defaults_file)
		end

		def default_config
			{
				:key_name => "judo",
				:instance_size => "m1.small",
				:ami32 => "ami-bb709dd2",  ## public ubuntu 9.10 ami - 32 bit
				:ami64 => "ami-55739e3c",  ## public ubuntu 9.10 ami - 64 bit
				:user => "ubuntu",
				:security_group => { "name" => "judo", "public_ports" => ["22"] },
				:availability_zone => "us-east-1d"  ## FIXME -- this should be state not config -- what if they differ - how to set?
			}
		end

#		def merged_config(name)
#			stack = load_config_stack(name)
#			stack.reverse.inject({}) { |sum,conf| sum.merge(conf) }
#		end

#		def load_config_stack(name, all = [])
#			return (all << defaults) if name.nil?
#			conf = read_config(name)
#			load_config_stack(conf["import"], all << conf)
#		end

		def repo_dir
			judo_config["repo"] || File.dirname(judo_dir)
		end

#		def group_dirs
#			Dir["#{repo_dir}/*/config.json"].map { |d| File.dirname(d) }
#		end

#		def group_dir(name)
#			group_dirs.select { |d| File.basename(d) == name }
#		end

#		def groups
#			group_dirs.map { |g| File.basename(g) }
#		end

#		def group
#			File.basename(group_dirs.detect { |d| Dir.pwd == d or Dir.pwd =~ /^#{d}\// }) rescue nil
#		end

#		def read_config(name)
#			begin
#				JSON.parse(File.read("#{group_dir(name)}/config.json"))
#			rescue Errno::ENOENT
#				{}
#			end
#		end

		def access_id
			judo_config["access_id"] || ENV["AWS_ACCESS_KEY_ID"] || (raise "please define access_id in #{judo_config_file} or in the env as AWS_ACCESS_KEY_ID")
		end
	
		def access_secret
			judo_config["access_secret"] || ENV["AWS_SECRET_ACCESS_KEY"] || (raise "please define access_secet in #{judo_config_file} or in the env as AWS_SECRET_ACCESS_KEY")
		end
		
		def ec2
			@ec2 ||= Aws::Ec2.new(access_id, access_secret, :logger => Logger.new(nil))
		end

### REMOVE
		def couchdb
			nil
#			@couchdb ||= CouchRest.database!(couch_url)
		end

		def couch_url
#			judo_config["couch_url"] || "http://127.0.0.1:5984/judo"
		end

## FIXME
		def keypair_file
			judo_config["keypair_file"] || "#{judo_dir}/keypair.pem"
		end

#		def connect
#			@@con = Aws::ActiveSdb.establish_connection(Config.access_id, Config.access_secret, :logger => Logger.new(nil))
#			one_time_setup unless setup?
#		end

## FIXME
		def one_time_setup
			puts "ONE TIME SETUP"
			Judo::Server.create_domain
		end

#		def setup?
#			Judo::Server.connection.list_domains[:domains].include? Judo::Server.domain
#		end
		
## FIXME
		def create_keypair
			## EC2 create_key_pair
			material = ec2.create_key_pair("judo")[:aws_material]
			File.open(keypair_file, 'w') { |f| f.write material }
			File.chmod 0600, keypair_file
		end

		## FIXME - this seems... lame
		def create_security_group
			## EC2 create_security_group
			ec2.create_security_group('judo', 'Judo')
			## EC2 authorize_security_group
			ec2.authorize_security_group_IP_ingress("judo", 22, 22,'tcp','0.0.0.0/0')
		rescue Aws::AwsError
		end

		def judo_config
			@config ||= read_judo_config
		end

		def judo_config_file
			"#{judo_dir}/config.yml"
		end

		def judo_dir
			@judo_dir ||= find_judo_dir(Dir.pwd) || abort("fatal: Not a judo repository (or any of the parent directories): .judo\nrun commands from the judo repository or type 'judo init' to setup the current directory as a new judo repository")
		end

		def find_judo_dir(check)
			if check == "/"
				if File.exists?("#{ENV['HOME']}/.judo")
					"#{ENV['HOME']}/.judo"
				else
					nil
				end
			else
				File.exists?(check + "/.judo") ? check + "/.judo" : find_judo_dir(File.dirname(check))
			end
		end

		def read_judo_config
			YAML.load File.read(judo_config_file)
		rescue Errno::ENOENT
			{}
		end

		def sdb
			@sdb = Aws::SdbInterface.new(access_id, access_secret, :logger => Logger.new(nil))
		end

		def s3
#			@s3 ||= RightAws::S3.new(access_id, access_secret, :logger => Logger.new(nil))
#			@s3 ||= Aws::S3.new(access_id, access_secret)
      @s3 = Fog::AWS::S3.new( :aws_access_key_id => access_id, :aws_secret_access_key => access_secret)
		end

		def s3_url(k)
			s3.get_object_url(judo_config["s3_bucket"], k,Time.now.to_i + 100_000_000)
		end

		def s3_put(k, file)
			s3.put_object(judo_config["s3_bucket"], k, file)
		end

		def collect(keys, prompt, &blk)
			k = keys.detect do |k| 
				printf "Looking in your environment for #{k}..."
				printf "found!" if ENV[k]
				printf "\n"
				ENV[k] 
			end
			value = ENV[k]
			retries = 3
			begin
				unless value
					printf "#{prompt}: "
					value = STDIN.readline
				end
				blk.call(value) if blk
				value
			rescue *[Interrupt, EOFError]
				puts "\nGoodbye!"
				exit(0)
			rescue Object => e
				fail "too many retries" if retries == 0
				puts "There was an error: #{e.class}:#{e.message}"
				puts "Try again or hit CTRL-C"
				value = nil
				retries -= 1
				retry
			end
				
		end
				
		def init
			### sooooo ugly
			require 'pp'
			fail "you are already inside a judo repository" if find_judo_dir(Dir.pwd)
			fail "./.git not found - judo configurations must be kept in a git repo.  type 'git init' to setup the git repo." unless File.exists? "./.git"
			aws_id =     collect(['AWS_ACCESS_KEY_ID', 'AMAZON_ACCESS_KEY_ID'],          "Please enter your AWS access key")
			aws_secret = collect(['AWS_SECRET_ACCESS_KEY', 'AMAZON_SECRET_ACCESS_KEY'],  "Please enter your AWS secret key") do |aws_secret|
				puts "Trying to connect to SimpleDB with #{aws_id}:#{aws_secret}"
				@sdb = Aws::SdbInterface.new(aws_id, aws_secret, :logger => Logger.new(nil))
				@sdb.create_domain("judo_servers")
				@sdb.create_domain("judo_config")
			end

			puts "setting up an s3 bucket"
			s3_bucket = ENV['SUMO_S3_BUCKET'] || "judo_#{rand(2**128).to_s(16)}"
   		Fog::AWS::S3.new( :aws_access_key_id => aws_id, :aws_secret_access_key => aws_secret).put_bucket(s3_bucket)

			puts "setting up an .judo/config.yml"
			system "mkdir .judo"
			File.open(".judo/config.yml","w") { |f| f.write({ "access_id" => aws_id, "access_secret" => aws_secret, "s3_bucket" => s3_bucket }.to_yaml) }

			puts "Setting up default config and keypair"
			system "mkdir default"
			keypair = "judo_#{rand(2**64).to_s(16)}"
			@ec2 = Aws::Ec2.new(access_id, access_secret, :logger => Logger.new(nil))
			material = @ec2.create_key_pair(keypair)[:aws_material]
			File.open("default/#{keypair}.pem", 'w') { |f| f.write material }
			File.chmod 0600, "default/#{keypair}.pem"
			File.open("default/config.json","w") { |f| f.write default_config.merge({ "keypair" => keypair }) }
			puts "congratulations! - you're ready to go!"
		end
	end
end
