require 'yaml'
require 'socket'
require 'fileutils'

require 'rubygems'
require 'right_aws'
require 'json'
require 'pp'

raise "Judo Currently Requires Ruby 1.8.7" unless RUBY_VERSION == "1.8.7"

class JudoError < RuntimeError ; end
class JudoInvalid < RuntimeError ; end

require File.dirname(__FILE__) + '/judo/base'
require File.dirname(__FILE__) + '/judo/config'
require File.dirname(__FILE__) + '/judo/group'
require File.dirname(__FILE__) + '/judo/server'
require File.dirname(__FILE__) + '/judo/snapshot'
require File.dirname(__FILE__) + '/judo/setup'

