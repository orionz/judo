require 'jeweler'

Jeweler::Tasks.new do |s|
	s.name = "judo"
	s.description = "The gentle way to manage and control ec2 instances"
	s.summary = s.description
	s.author = "Orion Henry"
	s.email = "orion@heroku.com"
	s.homepage = "http://github.com/orionz/judo"
	s.rubyforge_project = "judo"
	s.files = FileList["[A-Z]*", "{bin,lib,spec}/**/*"]
	s.executables = %w(judo)
	s.add_dependency "uuidtools"
	s.add_dependency "aws"
	s.add_dependency "thor"
	s.add_dependency "json"
	s.add_dependency "fog"
end

Jeweler::RubyforgeTasks.new

desc 'Run specs'
task :spec do
	sh 'bacon -s spec/*_spec.rb'
end

task :default => :spec

