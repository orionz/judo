module Judo
  class Base
    attr_accessor :group

    def self.defaults
      {
        :access_id     => ENV['AWS_ACCESS_KEY_ID'],
        :access_secret => ENV['AWS_SECRET_ACCESS_KEY']
      }
    end

    def initialize(options)
      @access_id     = options[:access_id]
      @access_secret = options[:access_secret]
    end

    def access_id
      @access_id || (raise JudoError, "no AWS Access ID specified")
    end

    def access_secret
      @access_secret || (raise JudoError, "no AWS Secret Key specified")
    end

    def bucket_name
      "judo_#{access_id}"
    end

    def server_domain
      "judo_servers"
    end

    def snapshot_domain
      "judo_snapshots"
    end

    def base_domain
      "judo_base"
    end

    def find_groups(names)
      return groups if names.include?(":all")
      names.map do |name|
        groups.detect { |g| g.displayname == name } || (raise JudoError, "No such group #{name}")
      end
    end

    def find_server(name)
      find_servers([name]).first
    end

    def find_servers(names)
      names.map do |name|
        servers.detect { |s| s.name == name || s.displayname == name } || (raise JudoError, "No such server #{name}")
      end
    end

    def find_servers_by_name_or_groups_with_not(*names)
      ok_servers = names.flatten.reject { |s| s =~ /^\^/ }
      not_servers = names.flatten.select { |s| s =~ /^\^/ }.map { |s| s =~ /^\^(.*)$/ ; $1 }

      find_servers_by_name_or_groups(ok_servers) - find_servers_by_name_or_groups(not_servers)
    end

    def find_servers_by_name_or_groups(*names)
      just_servers = names.flatten.reject { |s| s =~ /^:/ }
      just_groups = names.flatten.select { |s| s =~ /^:/ }

      [find_groups(just_groups).map { |g| g.servers } + find_servers(just_servers)].flatten
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
      @servers ||= servers_state.map { |id,data| Judo::Server.new(self, id, data["group"].first) }
    end

    def new_server_id
      rand(2**32).to_s(36)
    end

    def mk_server_name(group)
      index = servers.map { |s| (s.name =~ /^#{s.group.name}.(\d*)$/); $1.to_i }.sort.last.to_i + 1
      "#{group}#{index}"
    end

    def create_server(name, group, options)
      s = Judo::Server.new(self, new_server_id, group)
      servers << s
      s.create(name, options)
      s
    end

    def new_snapshot(name, server)
      s = Judo::Snapshot.new(self, name, server)
      snapshots << s
      s
    end

    def get_group(name)
      group = groups.detect { |g| g.name == name }
      group ||= Judo::Group.new(self, name)
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
      @groups ||= group_versions.map { |name,ver| Judo::Group.new(self, name) }
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
      Aws::S3Generator::Key.new(bucket, k).get
    end

    def s3_get(k)
      bucket.get(k)
    end

    def s3_put(k, file)
      bucket.put(k, file)
    end

    def get(key)
      state[key] && [state[key]].flatten.first
    end

    ## i'm copy pasting code from server - this needs to be its own module
    def update(attrs)
      sdb.put_attributes(base_domain, "judo", attrs, :replace)
      state.merge! attrs
    end

    def state
      @state ||= sdb.get_attributes(base_domain, "judo")[:attributes]
    end

    def ensure_setup
      ensure_init
      ensure_db_version
    end

    def ensure_init
      if !has_init?
        init_sdb
        init_security_group
        init_keypair
      end
    end

    def has_init?
      sdb.list_domains[:domains].include?(base_domain)
    end

    def init_sdb
      task("Initializing Judo SDB") do
        sdb.create_domain(base_domain)
      end
    end

    def init_security_group
      task("Initializing Judo Security Group") do
        begin
          ec2.create_security_group('judo', 'Judo')
          ec2.authorize_security_group_IP_ingress("judo", 22, 22,'tcp','0.0.0.0/0')
        rescue Aws::AwsError => e
          raise unless e.message =~ /InvalidGroup.Duplicate/
        end
      end
    end

    def init_keypair
      task("Initializing Judo Keypair") do
        ec2.delete_key_pair("judo")
        material = ec2.create_key_pair("judo")[:aws_material]
        s3_put("judo.pem", material)
      end
    end

    def keypair_file(&blk)
      Tempfile.open("judo.pem") do |file|
        file.write(s3_get("judo.pem"))
        file.flush
        blk.call(file.path)
      end
    end

    def set_db_version(new_version)
      update "dbversion" => new_version
    end

    def get_db_version
      get("dbversion").to_i
    end

    def ensure_db_version
      case get_db_version
      when 0
        task("Upgrading Judo SDB from version 0 to 2") do
          sdb.create_domain(server_domain)
          sdb.create_domain(snapshot_domain)
          set_db_version(2)
        end
      when 1
        task("Upgrading Judo SDB from version 1 to 2") do
          sdb.create_domain(snapshot_domain)
          set_db_version(2)
        end
      when 2
        # current version
      else
        raise JudoError, "Judo SDB has higher version (#{get_db_version}) " +
                         "than current gem (2) - please upgrade Judo"
      end
    end
  end
end
