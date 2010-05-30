module Judo
  class Group
    attr_accessor :name, :version

    def initialize(base, name, version)
      @base = base
      @name = name
      @version = version
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
      @base.servers.select { |s| server_ids.include?(s.name) }
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
      @base.task("Compiling #{self} version #{version + 1}") do
        @version = @version + 1
        conf = read_config
        raise JudoError, "config option 'import' no longer supported" if conf["import"]
        Dir.chdir(@base.repo) do |d|
            puts ""
            system "tar czvf #{tar_file} #{name}"
            puts "Uploading config to s3..."
            @base.s3_put(version_config_file(@version), conf.to_json)
            puts "Uploading userdata.erb to s3..."
            @base.s3_put(version_userdata_file(@version), read_userdata)
            puts "Uploading tar file to s3..."
            @base.s3_put(tar_file, File.new(tar_file).read(File.stat(tar_file).size))
            File.delete(tar_file)
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

    def tar_file
      "#{name}.#{version}.tar.gz"
    end

    def s3_url
      @url = @base.s3_url(tar_file)
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

    def config_file
      "#{dir}/config.json"
    end

    def default_userdata_file
        File.expand_path(File.dirname(__FILE__) + "/default_userdata.erb")
    end

    def userdata_file
      "#{dir}/userdata.erb"
    end

    def read_userdata
      if File.exists?(userdata_file)
        File.read(userdata_file)
      else
        puts "File userdata.erb not found: using #{default_userdata_file} instead"
        File.read(default_userdata_file)
      end
    end

    def read_config
        JSON.parse(File.read(config_file))
      rescue Errno::ENOENT
        raise JudoError, "No config file #{config_file}"
    end

    def delete_server(server)
      sdb.delete_attributes(@base.base_domain, "groups", name => server.id)
    end

    def to_s
      ":#{name}"
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

