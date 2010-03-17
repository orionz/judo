module Judo
	class Group
		attr_accessor :name, :dir

		def self.dirs
			Dir["#{Judo::Config.repo_dir}/*/config.json"].map { |d| File.dirname(d) }
		end

		def self.all
			@@all ||= (dirs.map { |d| new(d) })
		end

		def self.find(name)
			all.detect { |d| d.name == name }
		end

		def self.[](name)
			find(name)
		end

		def self.current
			all.detect { |d| Dir.pwd == d.dir or Dir.pwd =~ /^#{d.dir}\// }
		end

		def initialize(dir, name = File.basename(dir))
			@name = name
			@dir = dir
		end

		def create_server(server_name)
			abort("Server needs a name") if server_name.nil?
#			abort("Already a server named #{server_name}") if Judo::Server.find_by_name(attrs[:name])  ## FIXME
#			Judo::Config.read_config(attrs[:group]) ## make sure the config is valid  ## FIXME

			server = Judo::Server.new server_name, self
			server.task("Creating server #{server_name}") do
				server.update "name" => server_name, "group" => name, "virgin" => true, "secret" => rand(2 ** 128).to_s(36)
				Judo::Config.sdb.put_attributes("judo_config", "groups", name => server_name)
			end
			server
		end
		
		def config
			@config ||= self.class.load_all(self)
		end
	
		def server_names
			Judo::Config.sdb.get_attributes("judo_config", "groups")[:attributes][@name] || []
		end

		def servers
			server_names.map { |n| Judo::Server.new(n, self) }
		end

		def version
			@version ||= (Judo::Config.sdb.get_attributes("judo_config", "group_versions")[:attributes][@name] || ["0"]).first.to_i
		end

		def set_version(new_version)
			@version = new_version
			Judo::Config.sdb.put_attributes("judo_config", "group_versions", { name => new_version }, :replace)
		end

		def compile
			tmpdir = "/tmp/kuzushi/#{name}"
			set_version(version + 1)
			puts "Compiling version #{version}"
			FileUtils.rm_rf(tmpdir)
			FileUtils.mkdir_p(tmpdir)
			Dir.chdir(tmpdir) do |d|
				attachments.each do |to,from|
					FileUtils.mkdir_p(File.dirname(to))
					if from =~ /^http:\/\//
						puts "curl '#{from}'"
						system "curl '#{from}' > #{to}"
						puts "#{to} is #{File.stat(to).size} bytes"
					else
						FileUtils.cp(from,to)
					end
				end
				File.open("config.json", "w") { |f| f.write(config.to_json) }
				Dir.chdir("..") do
					system "tar czvf #{tar_file} #{name}"
					puts "Uploading to s3..."
					Judo::Config.s3_put(tar_file, File.new(tar_file))
				end
			end
		end

		def tar_file
			"#{name}.#{version}.tar.gz"  ## FIXME needs to incorprate #{config version} "#{name}.#{version}.tar.gz"
		end

		def s3_url 
			@url = Judo::Config.s3_url(tar_file)
		end

		def cp_file
			FileUtil.mkdir_p(tmpdir)
		end

		def parent
			self.class.find(config["import"])
		end

		def extract_file(type, name, files)
			path = "#{dir}/#{type}s/#{name}"
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

		def attachments
			extract(config, {})
		end

		def self.load_all(group, configs = [])
			return configs.reverse.inject({}) { |sum,conf| sum.merge(conf) } unless group
			raw_config = group.read_config
			load_all(find(raw_config["import"]), configs << raw_config)
		end

		def config_file
			"#{dir}/config.json"
		end

		def read_config
			begin
				JSON.parse(File.read(config_file))
			rescue Errno::ENOENT
				{}
			end
		end

		def delete_server(server)
			sdb.delete_attributes("judo_config", "groups", name => server.name)
		end

		def to_s
			name
		end

		def sdb
			Judo::Config.sdb
		end
	end
end

