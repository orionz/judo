module Judo
  module Config
    extend self

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

#    def create_security_group
#      ## EC2 create_security_group
#      ec2.create_security_group('judo', 'Judo')
#      ## EC2 authorize_security_group
#      ec2.authorize_security_group_IP_ingress("judo", 22, 22,'tcp','0.0.0.0/0')
#    rescue Aws::AwsError
#    end

    def judo_config
      @config ||= read_judo_config
    end

    def judo_config_file
      "#{judo_dir}/config.yml"
    end

    def judo_dir
      @judo_dir ||= find_judo_dir(Dir.pwd) || abort("fatal: Not a judo repository (or any of the parent directories): .judo\nrun commands from the judo repository or type 'judo init' to setup the current directory as a new judo repository")
    end

    def self.dirs
      Dir["#{Judo::Config.repo_dir}/*/config.json"].map { |d| File.dirname(d) }
    end

    def self.all
      @@all ||= (dirs.map { |d| new(d) })
    end

    def self.current
      all.detect { |d| Dir.pwd == d.dir or Dir.pwd =~ /^#{d.dir}\// }
    end

    def default_options(pwd, dir = find_judo_dir(pwd))
      puts "PWD: #{pwd}"
      puts "DIR: #{dir}"
      config = YAML.load File.read("#{dir}/config.yml")
      repo_dir = config["repo"] || File.dirname(dir)
      group_config = Dir["#{repo_dir}/*/config.json"].detect { |d| File.dirname(d) == pwd }
      {
        :judo_dir      => dir,
        :group         => group_config ? File.basename(File.dirname(group_config)) : nil,
        :repo          => repo_dir,
        :bucket        => config["s3_bucket"],
        :access_id     => config["access_id"],
        :access_secret => config["access_secret"]
      }.delete_if { |key,value| value.nil? }
    rescue Object => e
      puts e.inspect
      {}
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
#      @version_ok ||= check_version
      @sdb
    end

    def s3
      @s3 ||= Aws::S3.new(access_id, access_secret, :logger => Logger.new(nil))
    end

    def s3_bucket
      @s3_bucket ||= s3.bucket(judo_config["s3_bucket"])
    end

    def s3_url(k)
      Aws::S3Generator::Key.new(s3_bucket, k).get
    end

    def s3_put(k, file)
      s3_bucket.put(k, file)
    end
  end
end
