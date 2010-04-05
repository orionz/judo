module Judo
  class Base
    attr_accessor :judo_dir, :repo, :group

    def initialize(options)
      @judo_dir      = options[:judo_dir]
      @repo          = options[:repo]
      @group         = options[:group]
      @bucket_name   = options[:bucket]
      @access_id     = options[:access_id]
      @access_secret = options[:access_secret]
    end

    def volumes
      @volumes ||= ec2.describe_volumes.map do |v|
        {
          :id          => v[:aws_id],
          :size        => v[:aws_size],
          :status      => v[:aws_status],
          :device      => v[:aws_device],
          :instance_id => v[:aws_instance_id],
          :attached_to => instance_id_to_judo(v[:aws_instance_id]),
          :assigned_to => servers.detect { |s| s.volumes.invert[v[:aws_id]] }
        }
      end
    end

    def ips
      @ips ||= ec2.describe_addresses.map do |ip|
        {
          :ip          => ip[:public_ip],
          :instance_id => ip[:instance_id],
          :attached_to => instance_id_to_judo(ip[:instance_id]),
          :assigned_to => ip_to_judo(ip[:public_ip])
        }
      end
    end

    def self.default_options(pwd, dir = find_judo_dir(pwd))
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

    def self.find_judo_dir(check)
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

    def sdb
      @sdb ||= Aws::SdbInterface.new(access_id, access_secret, :logger => Logger.new(nil))
    end

    def fetch_servers_state
      s = {}
      sdb.select("select * from #{Judo::Server.domain}")[:items].each do |group|
        group.each do |key,val|
          s[key] = val
        end
      end
      s
    end

    def servers_state
      @servers_state ||= fetch_servers_state
    end

    def servers
      @servers ||= servers_state.map { |name,data| Judo::Server.new(self, name, data["group"].first) }
    end

    def new_server(name, group)
      s = Judo::Server.new(self, name, group)
      servers << s
      s
    end
    
    def get_group(name)
      group = groups.detect { |g| g.to_s == name }
      group ||= Judo::Group.new(self, name, 0)
      group
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

    def groups
      @groups ||= group_versions.map { |name,ver| Judo::Group.new(self, name, ver.first.to_i ) }
    end

    def reload_ec2_instances
      @ec2_instance = nil
    end

    def ec2_instances
      @ec2_instance ||= ec2.describe_instances
    end

    def ec2
      @ec2 ||= Aws::Ec2.new(access_id, access_secret, :logger => Logger.new(nil))
    end

    def groups_config
      @groups_config ||= sdb.get_attributes("judo_config", "groups")[:attributes]
    end

    def group_versions
      @group_version ||= sdb.get_attributes("judo_config", "group_versions")[:attributes]
    end

    def ip_to_judo(ip)
      servers.detect { |s| s.elastic_ip == ip }
    end

    def instance_id_to_judo(instance_id)
      servers.detect { |s| s.instance_id and s.instance_id == instance_id }
    end

    def s3
      @s3 ||= Aws::S3.new(access_id, access_secret, :logger => Logger.new(nil))
    end

    def bucket
      @bucket ||= s3.bucket(bucket_name)
    end

    def s3_url(k)
      Aws::S3Generator::Key.new(bucket, k).get
    end

    def s3_get(k)
      bucket.get(k)
    end

    def s3_put(k, file)
      bucket.put(k, file)
    end

    def repo
      raise JudoError, "no repo dir specified" unless @repo
      raise JudoError, "repo dir not found" unless File.exists?(@repo)
      @repo
    end

    def access_id
      @access_id || (raise JudoError, "no AWS Access ID specified")
    end

    def access_secret
      @access_secret || (raise JudoError, "no AWS Secret Key specified")
    end

    def bucket_name
      @bucket_name || (raise JudoError, "no S3 bucket name specified")
    end

    def db_version
      1
    end

    def get_db_version
      version = @sdb.get_attributes("judo_config", "judo")[:attributes]["dbversion"]
      version and version.first.to_i or db_version
    end

    def check_version
      ## FIXME - call this somewhere
      raise JduoError, "judo db is newer than the current gem - upgrade judo and try again" if get_db_version > db_version
    end

  end
end
