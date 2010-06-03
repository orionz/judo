require 'jeweler'

Jeweler::Tasks.new do |s|
	s.name = "judo"
	s.description = "The gentle way to manage and control ec2 instances"
	s.summary = s.description
	s.author = "Orion Henry"
	s.email = "orion@heroku.com"
	s.homepage = "http://github.com/orionz/judo"
	s.rubyforge_project = "judo"
	s.files = FileList["[A-Z]*", "{bin,default,lib,spec}/**/*"]
	s.executables = %w(judo)
	s.add_dependency "aws",  [">= 2.3.8"]
	s.add_dependency "json"
	s.add_dependency "activesupport"
end

Jeweler::RubyforgeTasks.new

desc 'Run specs'
task :spec do
	sh 'bacon -s spec/*_spec.rb'
end

task :default => :spec

