require 'rubygems'
require 'aws'
require 'right_aws'
require 'sdb/active_sdb' ##
require 'yaml'
require 'socket'
require 'json'
require 'couchrest'  ##
require 'fileutils'

require 'fog'
require 'fog/aws/s3'

require File.dirname(__FILE__) + '/config'
require File.dirname(__FILE__) + '/group'
require File.dirname(__FILE__) + '/server'
require File.dirname(__FILE__) + '/couchrest_hacks'
