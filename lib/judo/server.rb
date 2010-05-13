module Judo
  class Server
    attr_accessor :name

    def initialize(base, name, group, version = nil)
      @base = base
      @name = name
      @group_name = group
    end

    def create(options)
      raise JudoError, "no group specified" unless @group_name

      snapshots = options[:snapshots]
      note = options[:note]

      version = options[:version]
      version ||= group.version

      if @name.nil?
        index = @base.servers.map { |s| (s.name =~ /^#{s.group.name}.(\d*)$/); $1.to_i }.sort.last.to_i + 1
        @name = "#{group.name}.#{index}"
      end

      raise JudoError, "there is already a server named #{name}" if @base.servers.detect { |s| s.name == @name and s != self}

      task("Creating server #{name}") do
        update "name" => name, "group" => @group_name, "note" => note, "virgin" => true, "secret" => rand(2 ** 128).to_s(36), "version" => version
        @base.sdb.put_attributes("judo_config", "groups", @group_name => name)
      end

      allocate_disk(snapshots)
      allocate_ip

      self
    end

    def group
      @group ||= @base.groups.detect { |g| g.name == @group_name }
    end

    def fetch_state
      @base.sdb.get_attributes(self.class.domain, name)[:attributes]
    end

    def state
      @base.servers_state[name] ||= fetch_state
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

    def size_desc
      if not running? or ec2_instance_type == instance_size
        instance_size
      else
        "#{ec2_instance_type}/#{instance_size}"
      end
    end

    def version_desc
      group.version_desc(version)
    end

    def version
      get("version").to_i
    end

    def update_version(new_version)
        update "version" => new_version
    end

    def kuzushi_action
      if virgin?
        if cloned?
          "start"
        else
          "init"
        end
      else
        "start"
      end
    end

    def note
      get("note")
    end

    def clone
      get("clone")
    end

    def cloned?
      !!clone
    end

    def virgin?
      get("virgin").to_s == "true"  ## I'm going to set it to true and it will come back from the db as "true" -> could be "false" or false or nil also
    end

    def secret
      get "secret"
    end

    def snapshots
      @base.snapshots.select { |s| s.server == self }
    end

    def volumes
      Hash[ (state["volumes"] || []).map { |a| a.split(":") } ]
    end

    def self.domain
      "judo_servers"
    end

    def update(attrs)
      @base.sdb.put_attributes(self.class.domain, name, attrs, :replace)
      state.merge! attrs
    end

    def add(key, value)
      @base.sdb.put_attributes(self.class.domain, name, { key => value })
      (state[key] ||= []) << value
    end

    def remove(key, value = nil)
      if value
        @base.sdb.delete_attributes(self.class.domain, name, key => value)
        state[key] - [value]
      else
        @base.sdb.delete_attributes(self.class.domain, name, [ key ])
        state.delete(key)
      end
    end

    def delete
      group.delete_server(self) if group
      @base.sdb.delete_attributes(self.class.domain, name)
    end

######## end simple DB access  #######

    def instance_size
      config["instance_size"]
    end

    def config
      group.config
    end

    def to_s
      "#{name}:#{@group_name}"
    end

    def allocate_disk(snapshots)
      if snapshots
        clone_snapshots(snapshots)
      else
        create_volumes
      end
    end

    def clone_snapshots(snapshots)
      snapshots.each do |device,snap_id|
        task("Creating EC2 Volume #{device} from #{snap_id}") do
          volume_id = @base.ec2.create_volume(snap_id, nil, config["availability_zone"])[:aws_id]
          add_volume(volume_id, device)
        end
      end
    end

    def create_volumes
      if config["volumes"]
        [config["volumes"]].flatten.each do |volume_config|
          device = volume_config["device"]
          if volume_config["media"] == "ebs"
            size = volume_config["size"]
            if not volumes[device]
              task("Creating EC2 Volume #{device} #{size}") do
                ### EC2 create_volume
                volume_id = @base.ec2.create_volume(nil, size, config["availability_zone"])[:aws_id]
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
    end

    def allocate_ip
      begin
        if config["elastic_ip"] and not elastic_ip
          ### EC2 allocate_address
          task("Adding an elastic ip") do
            ip = @base.ec2.allocate_address
            add_ip(ip)
          end
        end
      rescue Aws::AwsError => e
        if e.message =~ /AddressLimitExceeded/
          invalid "Failed to allocate ip address: Limit Exceeded"
        else
          raise
        end
      end
    end

    def task(msg, &block)
      @base.task(msg, &block)
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
      @base.ec2.describe_volumes( volumes.values )
    end

    def remove_ip
      @base.ec2.release_address(elastic_ip) rescue nil
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
      @base.ec2_instances.detect { |e| e[:aws_instance_id] == instance_id } or {}
    end

    def running?
      ## other options are "terminated" and "nil"
      ["pending", "running", "shutting_down", "degraded"].include?(ec2_state)
    end

    def start(new_version = nil)
      invalid "Already running" if running?
      invalid "No config has been commited yet, type 'judo commit'" unless group.version > 0
      task("Updating server version")      { update_version(new_version) } if new_version
      task("Starting server #{name}")      { launch_ec2 }
      task("Wait for server")              { wait_for_running } if elastic_ip or has_volumes?
      task("Attaching ip")                 { attach_ip } if elastic_ip
      task("Attaching volumes")            { attach_volumes } if has_volumes?
    end

    def restart(force = false)
      stop(force) if running?
      start
    end

    def generic_name?
      name =~ /^#{group}[.]\d*$/
    end

    def generic?
      volumes.empty? and not has_ip? and generic_name?
    end

    def invalid(str)
      raise JudoInvalid, str
    end

    def force_detach_volumes
      volumes.each do |device,volume_id|
        task("Force detaching #{volume_id}") do
          @base.ec2.detach_volume(volume_id, instance_id, device, true) rescue nil
        end
      end
    end

    def stop(force = false)
      invalid "not running" unless running?
      ## EC2 terminate_isntaces
      task("Terminating instance") { @base.ec2.terminate_instances([ instance_id ]) }
      force_detach_volumes if force
      wait_for_volumes_detached if volumes.size > 0
      remove "instance_id"
    end

    def launch_ec2
#      validate

      ## EC2 launch_instances
      ud = user_data
      debug(ud)
      result = @base.ec2.launch_instances(ami,
        :instance_type => config["instance_size"],
        :availability_zone => config["availability_zone"],
        :key_name => config["key_name"],
        :group_ids => security_groups,
        :user_data => ud).first
      update "instance_id" => result[:aws_instance_id], "virgin" => false
    end

    def debug(str)
      return unless ENV['JUDO_DEBUG'] == "1"
      puts "<JUDO_DEBUG>#{str}</JUDO_DEBUG>"
    end

    def security_groups
      [ config["security_group"] ].flatten
    end

    def console_output
      invalid "not running" unless running?
      @base.ec2.get_console_output(instance_id)[:aws_output]
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

    def wait_for_running
      loop do
        return if ec2_state == "running"
        reload
        sleep 1
      end
    end

    def wait_for_hostname
      loop do
        reload
        return hostname if hostname
        sleep 1
      end
    end

    def wait_for_volumes_detached
      begin
        task("Wait for volumes to detach") do
          Timeout::timeout(60) do
            loop do
              break if ec2_volumes.reject { |v| v[:aws_status] == "available" }.empty?
              sleep 2
            end
          end
        end
      rescue Timeout::Error
        puts "failed!"
        force_detach_volumes
        retry
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
      invalid "not running" unless running?
      loop do
        begin
          reload
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
      @base.ec2.associate_address(instance_id, elastic_ip)
    end

    def dns_name
      return nil unless elastic_ip
      `dig +short -x #{elastic_ip}`.strip
    end

    def attach_volumes
      return unless running?
      volumes.each do |device,volume_id|
        ### EC2 attach_volume
        @base.ec2.attach_volume(volume_id, instance_id, device)
      end
    end

    def remove_volume(volume_id, device)
      task("Deleting #{device} #{volume_id}") do
        ### EC2 delete_volume
        @base.ec2.delete_volume(volume_id)
        remove "volumes", "#{device}:#{volume_id}"
      end
    end

    def add_volume(volume_id, device)
      invalid("Server already has a volume on that device") if volumes[device]

      add "volumes", "#{device}:#{volume_id}"

      @base.ec2.attach_volume(volume_id, instance_id, device) if running?

      volume_id
    end

    def connect_ssh
      wait_for_ssh
      system "chmod 600 #{group.keypair_file}"
      system "ssh -i #{group.keypair_file} #{config["user"]}@#{hostname}"
    end

    def ec2_instance_type
      ec2_instance[:aws_instance_type] rescue nil
    end

    def ip
      hostname || config["state_ip"]
    end

    def reload
      @base.reload_ec2_instances
      @base.servers_state.delete(name)
    end

    def user_data
      <<USER_DATA
#!/bin/sh

export DEBIAN_FRONTEND="noninteractive"
export DEBIAN_PRIORITY="critical"
export JUDO_ID='#{name}'
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
      @base.create_security_group

      ### EC2 desctibe_key_pairs
      k = @base.ec2.describe_key_pairs.detect { |kp| kp[:aws_key_name] == config["key_name"] }

      if k.nil?
        if config["key_name"] == "judo"
          @base.create_keypair
        else
          raise "cannot use key_pair #{config["key_name"]} b/c it does not exist"
        end
      end
    end

    def snapshot(name)
      snap = @base.new_snapshot(name, self.name)
      snap.create
    end

    def swapip(other)
      ip1 = elastic_ip
      ip2 = other.elastic_ip
      raise JudoError, "Server must have an elastic IP to swap" unless ip1 and ip2

      task("Swapping Ip Addresses") do 
        @base.ec2.disassociate_address(ip1)
        @base.ec2.disassociate_address(ip2)

        @base.ec2.associate_address(instance_id, ip2)
        @base.ec2.associate_address(other.instance_id, ip1)

        update "elastic_ip" => ip2
        other.update "elastic_ip" => ip1
      end
    end

    def <=>(s)
      [group.name, name] <=> [s.group.name, s.name]
    end

  end
end
