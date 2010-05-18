module Judo
  class Snapshot
    attr_accessor :name, :server_name

    def self.domain
      "judo_snapshots"
    end

    def initialize(base, name, server_name)
      @base = base
      @name = name
      @server_name = server_name
    end

    def server
      @server ||= @base.servers.detect { |s| s.name == @server_name }
    end

    def fetch_state
      @base.sdb.get_attributes(@base.snapshot_domain, name)[:attributes]
    end

    def state
      @base.snapshots_state[name] ||= fetch_state
    end

    def group_name
      get("group")
    end

    def version
      get("version").to_i
    end

    def devs
      Hash[ (state["devs"] || []).map { |a| a.split(":") } ]
    end

    def create
      raise JudoError,"snapshot already exists" unless state.empty?
      raise JudoError,"server has no disks to clone: #{server.volumes}" if server.volumes.empty?
      @base.task("Snapshotting #{server.name}") do
        devs = server.volumes.map do |dev,vol|
          "#{dev}:#{@base.ec2.create_snapshot(vol)[:aws_id]}"
        end
        @base.sdb.put_attributes(@base.snapshot_domain, name, { "version" => server.version, "devs" => devs, "server" => server.name, "group" => server.group.name }, :replace)
        server.add "snapshots", name
      end
    end

    def clone(new_server, version = self.version)
      raise JudoError, "cannot clone, snapshotting not complete" unless completed?
      server = @base.new_server(new_server, group_name)
      server.create( :version => version, :snapshots => devs)
      server.update "clone" => name ##, "secret" => rand(2 ** 128).to_s(36)  ## cant change this till kuzushi knows about a post-clone operation
    end

    def delete
      @base.sdb.delete_attributes(@base.snapshot_domain, name)
      server.remove "snapshots", name
    end

    def get(key)
      state[key] && [state[key]].flatten.first
    end

    def destroy
      devs.each do |dev,snapshot_id|
        @base.task("Deleting snapshot #{snapshot_id}") do
          begin
            @base.ec2.delete_snapshot(snapshot_id)
          rescue Object => e
            puts "Error destrotying snapshot #{e.message}"
          end
        end
      end
      delete
    end

    def ec2_ids
      devs.values
    end

    def completed?
      not @base.ec2_snapshots.select { |s| ec2_ids.include? s[:aws_id] }.detect { |s| s[:aws_status] != "completed" }
    end

    def size(snap_id)
      @base.ec2_snapshots.detect { |s| s[:aws_id] == snap_id }
    end

    def version_desc
      group.version_desc(version)
    end

    def group
      @group ||= @base.groups.detect { |g| g.name == group_name }
    end

    def fetch_state
      @base.sdb.get_attributes(@base.snapshot_domain, name)[:attributes]
    end
  end
end
