module Sumo
	class Group
		attr_accessor :name, :dir

    def self.dirs
      Dir["#{Sumo::Config.repo_dir}/*/config.json"].map { |d| File.dirname(d) }
    end

		def self.all
			@@all ||= dirs.map { |d| new(d) }
		end

		def self.find(name)
			all.detect { |d| d.name == name }
		end

		def self.[](name)
			find(name)
		end

    def self.current
      File.basename(all.detect { |d| Dir.pwd == d.dir or Dir.pwd =~ /^#{d}\// }) rescue nil
    end

		def initialize(dir)
			@name = File.basename(dir)
			@dir = dir
		end
		
		def config
			@config ||= self.class.load_all(self)
		end

		def servers
			Server.find_all_by_group(name)
		end

		def compile
			tmpdir = "/tmp/kuzushi/#{name}"
			FileUtils.rm_rf(tmpdir)
			FileUtils.mkdir_p(tmpdir)
			Dir.chdir(tmpdir) do |d|
				attachments.each do |to,from|
					FileUtils.mkdir_p(File.dirname(to))
					FileUtils.cp(from,to)
				end
				File.open("config.json", "w") { |f| f.write(config.to_json) }
				Dir.chdir("..") do
					system "tar czvf #{tar_file} #{name}"
					puts "Uploading to s3..."
					Sumo::Config.s3_put(tar_file, File.new(tar_file))
				end
			end
		end

		def tar_file
			"#{name}.tar.gz"
		end

		def s3_url 
			@url = Sumo::Config.s3_url(tar_file)
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
					extract(v, files) if v.is_a? Hash
					case key
						when *[ "init", "before", "after" ]
							extract_file(:script, v, files) unless v =~ /^#!/
						when "local_packages"
							extract_file(:package, "#{v}*", files)
						when "template"
							extract_file(:template, v, files)
						when "source"
							extract_file(:file, v, files) unless config["template"]
						when "file"
							extract_file(:file, File.basename(v), files) unless config["template"] or config["source"]
					end
				end
			end
			files
		end

		def attachments
			extract(config, {})
		end

		def self.load_all(group, configs = [])
      return configs.reverse.inject({}) { |sum,conf| sum.merge(conf) } unless group
			raw_config = group.read_config
			load_all(find(raw_config["import"]), configs << raw_config)
		end

    def read_config
      begin
        JSON.parse(File.read("#{dir}/config.json"))
      rescue Errno::ENOENT
        {}
      end
    end
	end
end

