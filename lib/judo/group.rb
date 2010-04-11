module Judo
  class Group
    attr_accessor :name, :version

#    def self.dirs
#      Dir["#{@base.repor}/*/config.json"].map { |d| File.dirname(d) }
#    end
#
#    def self.all
#      @@all ||= (dirs.map { |d| new(d) })
#    end
#
#    def self.find(name)
#      all.detect { |d| d.name == name }
#    end
#
#    def self.[](name)
#      find(name)
#    end
#
#    def self.current
#      all.detect { |d| Dir.pwd == d.dir or Dir.pwd =~ /^#{d.dir}\// }
#    end

#    def initialize(base, dir, name = File.basename(dir))
    def initialize(base, name, version)
      @base = base
      @name = name
      @version = version
      puts "VERSION #{name} #{version} #{@version}"
#      @dir = dir
    end

#    def create_server(server_name)
#      abort("Server needs a name") if server_name.nil?
#
##      abort("Already a server named #{server_name}") if Judo::Server.find_by_name(attrs[:name])  ## FIXME
##      @base.read_config(attrs[:group]) ## make sure the config is valid  ## FIXME
#
#      server = Judo::Server.new base, server_name, name
#      server.task("Creating server #{server_name}") do
#        server.update "name" => server_name, "group" => name, "virgin" => true, "secret" => rand(2 ** 128).to_s(36)
#        @base.sdb.put_attributes("judo_config", "groups", name => server_name)
#      end
#      server
#    end

    def config
      @config ||= load_config
    end

    def build_config
      @build_config ||= all_configs.reverse.inject({}) { |sum,conf| sum.merge(conf) }
    end

    def server_names
      @server_names ||= (@base.groups_config[@name] || [])
    end

    def servers
      @base.servers.select { |s| server_names.include?(s.name) }
    end

#    def version
#      @version ||= (@base.group_versions[@name] || ["0"]).first.to_i
#    end

    def load_config
        JSON.load @base.s3_get(version_config_file)
      rescue Aws::AwsError
       raise JudoError, "No config stored: try 'judo commit #{to_s}'"
    end

    def set_version
      @base.sdb.put_attributes("judo_config", "group_versions", { name => version }, :replace)
    end

    def compile
      tmpdir = "/tmp/kuzushi/#{name}"
      puts "Compiling #{self} version #{version}"
      @version = @version + 1
      FileUtils.rm_rf(tmpdir)
      FileUtils.mkdir_p(tmpdir)
      new_config = build_config
      Dir.chdir(tmpdir) do |d|
        attachments(new_config).each do |to,from|
          FileUtils.mkdir_p(File.dirname(to))
          if from =~ /^http:\/\//
            puts "curl '#{from}'"
            system "curl '#{from}' > #{to}"
            puts "#{to} is #{File.stat(to).size} bytes"
          else
            FileUtils.cp(from,to)
          end
        end
        File.open("config.json", "w") { |f| f.write(new_config.to_json) }
        Dir.chdir("..") do
          system "tar czvf #{tar_file} #{name}"
          puts "Uploading to s3..."
          @base.s3_put(tar_file, File.new(tar_file))
          @base.s3_put(version_config_file, new_config.to_json)
        end
      end
      set_version
    end

    def version_config_file
      "#{name}.#{version}.json"
    end

    def tar_file
      "#{name}.#{version}.tar.gz"
    end

    def s3_url
      @url = @base.s3_url(tar_file)
    end

    def cp_file
      FileUtil.mkdir_p(tmpdir)
    end

    def extract_file(type, name, files)
      path = "#{dir}/#{type}s/#{name}"
      puts "[#{name}] #{path}"
      found = Dir[path]
      if not found.empty?
        found.each { |f| files["#{type}s/#{File.basename(f)}"] = f }
      elsif parent
        parent.extract_file(type, name, files)
      else
        raise "Cannot find file #{name} of type #{type}"
      end
    end

    def extract(config, files)
      config.each do |key,value|
        [value].flatten.each do |v|   ### cover "packages" : ["a","b"], "packages" : "a", "packages":[{ "file" : "foo.pkg"}]
          if v.is_a? Hash
            extract(v, files)
          else
            case key
            when *[ "init", "before", "after" ]
              extract_file(:script, v, files) unless v =~ /^#!/
            when "package"
              files["packages/#{v}_i386.deb"]  = "#{config["source"]}#{v}_i386.deb"
              files["packages/#{v}_amd64.deb"] = "#{config["source"]}#{v}_amd64.deb"
            when "local_packages"
              extract_file(:package, "#{v}_i386.deb", files)
              extract_file(:package, "#{v}_amd64.deb", files)
            when "template"
              extract_file(:template, v, files)
            when "source"
              extract_file(:file, v, files) unless config["template"] or config["package"]
            when "file"
              extract_file(:file, File.basename(v), files) unless config["template"] or config["source"]
            end
          end
        end
      end
      files
    end

    def keypair_file
      extract_file(:keypair, config["key_name"] + ".pem" , {}).first
    end

    def attachments(c = config)
      extract(c, {})
    end

    def raw_config
      @raw_config ||= read_config
    end

    def parent
      @parent ||= @base.groups.detect { |p| p.name == raw_config["import"] }
      raise JudoError, "Parent group #{raw_config["import"]} must be commited" if raw_config["import"] and @parent.nil?
      @parent
    end

    def destroy
      servers.each { |s| s.destroy }
      @base.task("Destring #{self}") do
        @base.groups.delete(self)
        @base.sdb.delete_attributes("judo_config", "groups", [ name ])
        @base.sdb.delete_attributes("judo_config", "group_versions", [ name ])
      end
    end

    def all_configs
      parent ? parent.all_configs.clone.unshift(raw_config) : [ raw_config ]
    end

    def dir
      "#{@base.repo}/#{name}/"
    end

    def config_file
      "#{dir}/config.json"
    end

    def read_config
        JSON.parse(File.read(config_file))
      rescue Errno::ENOENT
        raise JudoError, "No config file #{config_file}"
    end

    def delete_server(server)
      sdb.delete_attributes("judo_config", "groups", name => server.name)
    end

    def to_s
      ":#{name}"
    end

    def sdb
      @base.sdb
    end
  end
end

