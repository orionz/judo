module Judo
	module Config
		extend self

		def method_missing?(method)
		end

		def db_version
			1
		end

		def get_db_version
      version = @sdb.get_attributes("judo_config", "judo")[:attributes]["dbversion"]
			version and version.first.to_i or db_version
		end

		def check_version
			abort "judo db is newer than the current gem - upgrade judo and try again" if get_db_version > db_version
		end

		def repo_dir
			judo_config["repo"] || File.dirname(judo_dir)
		end

		def access_id
			judo_config["access_id"]
		end
	
		def access_secret
			judo_config["access_secret"]
		end
		
		def get_ec2(aws_id, aws_key)
			Aws::Ec2.new(aws_id, aws_key, :logger => Logger.new(nil))
		end

		def ec2
			@ec2 ||= get_ec2(access_id, access_secret)
		end

#		def create_security_group
#			## EC2 create_security_group
#			ec2.create_security_group('judo', 'Judo')
#			## EC2 authorize_security_group
#			ec2.authorize_security_group_IP_ingress("judo", 22, 22,'tcp','0.0.0.0/0')
#		rescue Aws::AwsError
#		end

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

		def get_sdb(aws_id, aws_key)
			Aws::SdbInterface.new(aws_id, aws_key, :logger => Logger.new(nil))
		end

		def sdb
			@sdb ||= get_sdb(access_id, access_secret)
#			@version_ok ||= check_version
			@sdb
		end

		def s3
      @s3 ||= Fog::AWS::S3.new( :aws_access_key_id => access_id, :aws_secret_access_key => access_secret)
		end

		def s3_url(k)
			s3.get_object_url(judo_config["s3_bucket"], k, Time.now.to_i + 100_000_000)
		end

		def s3_put(k, file)
			s3.put_object(judo_config["s3_bucket"], k, file)
		end
	end
end
