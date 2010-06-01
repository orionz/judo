module Judo
  class Group
    attr_accessor :name, :version

    def initialize(base, name)
      @base = base
      @name = name
    end

    def version
      @version ||= (@base.group_versions[@name] || [0]).first.to_i
    end

    def userdata(version)
      (@userdata ||= {})[version] ||= load_userdata(version)
    end

    def config(version)
      (@config ||= {})[version] ||= load_config(version)
    end

    def server_ids
      @server_ids ||= (@base.groups_config[@name] || [])
    end

    def servers
      @base.servers.select { |s| server_ids.include?(s.id) }
    end

    def load_userdata(version)
        @base.s3_get(version_userdata_file(version))
      rescue Aws::AwsError
       raise JudoError, "No userdata stored: try 'judo commit #{to_s}'"
    end

    def load_config(version)
        JSON.load @base.s3_get(version_config_file(version))
      rescue Aws::AwsError
       raise JudoError, "No config stored: try 'judo commit #{to_s}'"
    end

    def set_version
      @base.sdb.put_attributes(@base.base_domain, "group_versions", { name => version }, :replace)
    end

    def compile
      raise JudoError, "Group name :all is reserved" if name == "all"
      @base.task("Compiling #{self} version #{version + 1}") do
        @version = version + 1
        raise JudoError, "can not find group folder #{dir}" unless File.exists?(dir)
        conf = JSON.parse(read_file('config.json'))
        raise JudoError, "config option 'import' no longer supported" if conf["import"]
        tar = tar_file(@version)
        Dir.chdir(@base.repo) do |d|
            puts ""
            system "tar czvf #{tar} #{name}"
            puts "Uploading config to s3..."
            @base.s3_put(version_config_file(@version), conf.to_json)
            puts "Uploading userdata.erb to s3..."
            @base.s3_put(version_userdata_file(@version), read_file('userdata.erb'))
            puts "Uploading tar file to s3..."
            @base.s3_put(tar, File.new(tar).read(File.stat(tar).size))
            File.delete(tar)
        end
        set_version
      end
    end

    def version_config_file(version)
      "#{name}.#{version}.json"
    end

    def version_userdata_file(version)
      "#{name}.#{version}.erb"
    end

    def tar_file(version)
      "#{name}.#{version}.tar.gz"
    end

    def s3_url(version)
      @url = @base.s3_url(tar_file(version))
    end


    def destroy
      servers.each { |s| s.destroy }
      @base.task("Destring #{self}") do
        @base.groups.delete(self)
        @base.sdb.delete_attributes(@base.base_domain, "groups", [ name ])
        @base.sdb.delete_attributes(@base.base_domain, "group_versions", [ name ])
      end
    end

    def dir
      "#{@base.repo}/#{name}/"
    end

    def default_userdata_file
        File.expand_path(File.dirname(__FILE__) + "/../../default/userdata.erb")
    end

    def read_file(name)
        File.read("#{dir}/#{name}")
      rescue Errno::ENOENT
        default = @base.default_file(name)
        puts "File #{name} not found: using #{default} instead"
        File.read default
    end

    def delete_server(server)
      sdb.delete_attributes(@base.base_domain, "groups", name => server.id)
    end

    def displayname 
      ":#{name}"
    end

    def to_s
      displayname
    end

    def sdb
      @base.sdb
    end

    def version_desc(v)
      if v == version
        "v#{v}"
      else
        "v#{v}/#{version}"
      end
    end
  end
end

