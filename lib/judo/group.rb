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

    def servers
      @base.servers.select { |s| s.group_name == name }
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
      @base.sdb.put_attributes(@base.base_domain,
        "group_versions", {name => version}, :replace)
    end

    def check_conf(conf)
      if conf["import"]
        raise JudoError, "config option 'import' no longer supported"
      end
    end

    def commit
      raise JudoError, "Group name all is reserved" if name == "all"
      @base.task("Compiling #{self} version #{version + 1}") do
        @version = version + 1
        conf = JSON.parse(File.read("#{name}/config.json"))
        userdata = File.read("#{name}/userdata.erb")
        tar = tar_file(@version)
        puts ""
        system "tar czvf #{tar} #{name}"
        puts "Uploading config to s3..."
        @base.s3_put(version_config_file(@version), conf.to_json)
        puts "Uploading userdata.erb to s3..."
        @base.s3_put(version_userdata_file(@version), userdata)
        puts "Uploading tar file to s3..."
        @base.s3_put(tar, File.new(tar).read(File.stat(tar).size))
        File.delete(tar)
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
      @base.task("Destroying servers in group #{self}") do
        servers.each { |s| s.destroy }
      end
      @base.task("Destroying group #{self}") do
        @base.groups.delete(self)
        @base.sdb.delete_attributes(@base.base_domain, "group_versions", [ name ])
      end
    end

    def displayname
      ":#{name}"
    end

    def to_s
      displayname
    end

    def version_desc(v)
      v == version ? "v#{v}" : "v#{v}/#{version}"
    end
  end
end

