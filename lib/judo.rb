require 'rubygems'
require 'active_support'
require 'right_aws'
require 'socket'
require 'fileutils'
require 'yaml'
require 'json'
require 'pp'

raise "Judo Currently Requires Ruby 1.8.7" unless RUBY_VERSION == "1.8.7"

class JudoError < RuntimeError ; end
class JudoInvalid < RuntimeError ; end

require File.dirname(__FILE__) + '/judo/base'
require File.dirname(__FILE__) + '/judo/group'
require File.dirname(__FILE__) + '/judo/server'
require File.dirname(__FILE__) + '/judo/snapshot'
