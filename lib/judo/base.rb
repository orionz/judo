
=begin
module Aws
  class Ec2
    API_VERSION       = "2009-11-30"  ## this didnt work
    def start_instances(instance_id)
      link = generate_request("StartInstances",  { 'InstanceId' => instance_id } )
      request_info(link, QEc2TerminateInstancesParser.new(:logger => @logger))
    rescue Exception
      on_exception
    end

    def stop_instances(instance_id)
      link = generate_request("StopInstances",  { 'InstanceId' => instance_id } )
      puts link.inspect
      result = request_info(link, QEc2TerminateInstancesParser.new(:logger => @logger))
      puts result.inspect
    rescue Exception
      on_exception
    end
  end
end
=end

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
      @domain        = options[:domain]
    end

    def volumes
      @volumes ||= ec2_volumes.map do |v|
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

    def sdb_domain(name)
      if @domain
        "#{@domain}_#{name}"
      else
        name
      end
    end

    def server_domain
      sdb_domain("judo_servers")
    end

    def snapshot_domain
      sdb_domain("judo_snapshots")
    end

    def base_domain
      sdb_domain("judo_config")
    end

    def self.default_options(pwd, dir = find_judo_dir(pwd))
      config = YAML.load File.read("#{dir}/config.yml")
      repo_dir = config["repo"] || File.dirname(dir)
      group_config = Dir["#{repo_dir}/*/config.json"].detect { |d| File.dirname(d) == pwd }
      {
        :judo_dir      => dir,
        :group         => group_config ? File.basename(File.dirname(group_config)) : nil,
        :repo          => repo_dir,
        :domain        => (config["domain"] || ENV['JUDO_DOMAIN']),
        :bucket        => (config["s3_bucket"] || ENV['JUDO_BUCKET']),
        :access_id     => (config["access_id"] || ENV['AWS_ACCESS_KEY_ID']),
        :access_secret => (config["access_secret"] || ENV['AWS_SECRET_ACCESS_KEY'])
      }.delete_if { |key,value| value.nil? }
    rescue Object => e
      {
        :access_id     => ENV['AWS_ACCESS_KEY_ID'],
        :access_secret => ENV['AWS_SECRET_ACCESS_KEY'],
        :bucket        => ENV['JUDO_BUCKET'],
        :domain        => ENV['JUDO_DOMAIN'],
      }.delete_if { |key,value| value.nil? }
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

    def fetch_snapshots_state
      s = {}
      sdb.select("select * from `#{snapshot_domain}`")[:items].each do |group|
        group.each do |key,val|
          s[key] = val
        end
      end
      s
    end

    def fetch_servers_state
      s = {}
      sdb.select("select * from `#{server_domain}`")[:items].each do |group|
        group.each do |key,val|
          s[key] = val
        end
      end
      s
    end

    def snapshots_state
      @snapshots_state ||= fetch_snapshots_state
    end

    def servers_state
      @servers_state ||= fetch_servers_state
    end

    def snapshots
      @snapshots ||= snapshots_state.map { |name,data| Judo::Snapshot.new(self, name, data["server"].first) }
    end

    def servers
      @servers ||= servers_state.map { |name,data| Judo::Server.new(self, name, data["group"].first) }
    end

    def new_server(name, group)
      s = Judo::Server.new(self, name, group)
      servers << s
      s
    end

    def new_snapshot(name, server)
      s = Judo::Snapshot.new(self, name, server)
      snapshots << s
      s
    end

    def get_group(name)
      group = groups.detect { |g| g.name == name }
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

    def ec2_volumes
      @ec2_volumes ||= ec2.describe_volumes
    end

    def ec2_snapshots
      @ec2_snapshots ||= ec2.describe_snapshots
    end

    def ec2_instances
      @ec2_instance ||= ec2.describe_instances
    end

    def ec2
      @ec2 ||= Aws::Ec2.new(access_id, access_secret, :logger => Logger.new(nil))
    end

    def groups_config
      @groups_config ||= sdb.get_attributes(base_domain, "groups")[:attributes]
    end

    def group_versions
      @group_version ||= sdb.get_attributes(base_domain, "group_versions")[:attributes]
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
      @bucket ||= s3.bucket(bucket_name, true)
    end

    def s3_url(k)
      Aws::S3Generator::Key.new(bucket, s3_key(k)).get
    end

    def s3_get(k)
      bucket.get( s3_key(k))
    end

    def s3_put(k, file)
      bucket.put( s3_key(k), file)
    end

    def s3_key(k)
      if @domain
        "#{@domain}/#{k}"
      else
        k
      end
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
      2
    end

    def upgrade_db
      case get_db_version
        when 0
          task("Upgrading Judo: Creating Snapshots SDB Domain") do
            sdb.create_domain(server_domain)
            sdb.create_domain(base_domain)
            sdb.create_domain(snapshot_domain)
            set_db_version(2)
          end
        when 1
          task("Upgrading Judo: Creating Snapshots SDB Domain") do
            sdb.create_domain(snapshot_domain)
            set_db_version(2)
          end
        else
          raise JduoError, "judo db is newer than the current gem - upgrade judo and try again"
      end
    end

    def set_db_version(new_version)
      @db_version = new_version
      sdb.put_attributes(base_domain, "judo", { "dbversion" => new_version }, :replace)
    end

    def get_db_version
      @db_version ||= (sdb.get_attributes(base_domain, "judo")[:attributes]["dbversion"] || []).first.to_i
    end

    def check_version
        upgrade_db if get_db_version != db_version
      rescue Aws::AwsError => e
        setup_sdb
        upgrade_db
    end

    def setup
      ## no need to setup bucket

      @repo ||= "." ## use cwd as default repo dir

      setup_sdb
      setup_security_group
      setup_judo_config
      setup_repo
      get_group("default").compile
    end

    def setup_sdb
      task("Trying to connect to SimpleDB") do
        sdb.create_domain(base_domain)
      end
    end

    def setup_security_group
      begin
        ec2.create_security_group('judo', 'Judo')
        ec2.authorize_security_group_IP_ingress("judo", 22, 22,'tcp','0.0.0.0/0')
      rescue Aws::AwsError => e
        raise unless e.message =~ /InvalidGroup.Duplicate/
      end
    end

    def setup_judo_config
      if judo_dir and File.exists?("#{judo_dir}/config.yml")
        puts "config already exists [#{judo_dir}/config.yml]"
        return
      end
      raise JudoError, "You must specify a repo dir" unless repo
      task("writing .judo/config.yml") do
        Dir.chdir(repo) do
          system "mkdir .judo"
          File.open(".judo/config.yml","w") do |f|
            f.write({ "access_id" => access_id, "access_secret" => access_secret, "s3_bucket" => bucket_name }.to_yaml)
          end
        end
      end
    end

    def setup_repo
      if File.exists?("#{repo}/default")
        puts "default group already exists [#{repo}/default]"
        return
      end
      task("Setting up default group") do
        Dir.chdir(repo) do
          system "mkdir -p default/keypairs"

          @keypair = "judo#{ec2.describe_key_pairs.map { |k| k[:aws_key_name] }.map { |k| k =~ /^judo(\d*)/; $1.to_i }.sort.last.to_i + 1}"
          material = ec2.create_key_pair(@keypair)[:aws_material]

          File.open("default/keypairs/#{@keypair}.pem", 'w') { |f| f.write material }
          File.chmod 0600, "default/keypairs/#{@keypair}.pem"
          File.open("default/config.json","w") { |f| f.write default_config }
        end
      end
    end

    def default_config
        <<DEFAULT
{
  "key_name":"#{@keypair}",
  "instance_type":"m1.small",
  "ami32":"ami-bb709dd2", // public ubuntu 9.10 ami - 32 bit
  "ami64":"ami-55739e3c", // public ubuntu 9.10 ami - 64 bit
  "user":"ubuntu",
  "security_group":"judo",
  "availability_zone":"us-east-1d"
}
DEFAULT
    end
  end
end
