module Judo
	class Setup
		def default_config
				<<DEFAULT
{
	"key_name":"#{@keypair}",
	"instance_size":"m1.small",
	"ami32":"ami-bb709dd2", // public ubuntu 9.10 ami - 32 bit
	"ami64":"ami-55739e3c", // public ubuntu 9.10 ami - 64 bit
	"user":"ubuntu",
	"security_group":"judo",
	"availability_zone":"us-east-1d"
}
DEFAULT
		end

		def getenv(key)
			printf "Looking in your environment for #{key}..."
			printf "found!" if ENV[key]
			printf "\n"
			ENV[key]
		end

		def request(query, default = "")
			printf "#{query} ['#{default}']: "
			input = STDIN.readline.strip
			input.empty? and default or input 
		end

		def check_setup
			abort "you are already inside a judo repository" if Judo::Config.find_judo_dir(Dir.pwd)
			abort "./.git not found - judo configurations must be kept in a git repo.  type 'git init' to setup the git repo." unless File.exists? "./.git"
		end

		def init
			check_setup
			@aws_access_id  ||= getenv('AWS_ACCESS_KEY_ID')
			@aws_access_id  ||= getenv('AWS_ACCESS_KEY_ID')
			@aws_secret_key ||= getenv('AWS_SECRET_ACCESS_KEY')
			@aws_secret_key ||= getenv('AMAZON_SECRET_ACCESS_KEY')
			@s3_bucket      ||= getenv('JUDO_S3_BUCKET')
			@s3_bucket      ||= "judo_#{rand(2**64).to_s(36)}"
			begin
				@aws_access_id  = request("Please enter your AWS access key",  @aws_access_id)
				@aws_secret_key = request("Please enter your AWS secret key" , @aws_secret_key)
				@s3_bucket      = request("Please enter an S3 bucket to use",  @s3_bucket)

				setup_default_server_group
				setup_default_security_group
				setup_bucket
				setup_db
				setup_judo_config

			rescue *[Interrupt, EOFError]
				puts "\nGoodbye!"
				exit(0)
			rescue Object => e
				puts "There was an error: #{e.class}:#{e.message}"
				puts "Try again or hit CTRL-C"
				retry
			end
		end

		def setup_db
			puts "Trying to connect to SimpleDB with #{@aws_access_id}"
			sdb.create_domain("judo_servers")
			sdb.create_domain("judo_config")
      olddb = sdb.get_attributes("judo_config", "judo")[:attributes]["dbversion"]
			abort "There is an existing judo database of a newer version - upgrade judo and try again" if olddb and olddb.first.to_i > Judo::Config.db_version
			sdb.put_attributes("judo_config", "judo", { "dbversion" => Judo::Config.db_version }, :replace)
		end

		def setup_default_security_group
			begin
				ec2.create_security_group('judo', 'Judo')
				ec2.authorize_security_group_IP_ingress("judo", 22, 22,'tcp','0.0.0.0/0')
			rescue Aws::AwsError => e
				raise unless e.message =~ /InvalidGroup.Duplicate/
			end
		end

		def setup_bucket
			puts "setting up an s3 bucket"
			Aws::S3.new(@aws_access_id, @aws_secret_key, :logger => Logger.new(nil)).bucket(@s3_bucket, true)
		end

		def setup_default_server_group
			puts "Setting up default group and keypair"
			system "mkdir -p default/keypairs"

			@keypair = "judo#{ec2.describe_key_pairs.map { |k| k[:aws_key_name] }.map { |k| k =~ /^judo(\d*)/; $1.to_i }.sort.last.to_i + 1}"
			material = ec2.create_key_pair(@keypair)[:aws_material]

			File.open("default/keypairs/#{@keypair}.pem", 'w') { |f| f.write material }
			File.chmod 0600, "default/keypairs/#{@keypair}.pem"
			File.open("default/config.json","w") { |f| f.write default_config }
		end

		def setup_judo_config
			puts "setting up an .judo/config.yml"
			system "mkdir .judo"
			File.open(".judo/config.yml","w") { |f| f.write({ "access_id" => @aws_access_id, "access_secret" => @aws_secret_key, "s3_bucket" => @s3_bucket }.to_yaml) }
		end

		def ec2
			@ec2 ||= Judo::Config.get_ec2(@aws_access_id, @aws_secret_key)
		end

		def sdb
			@sdb ||= Judo::Config.get_sdb(@aws_access_id, @aws_secret_key)
		end

	end
end
