# Copyright 2009 Zerigo, Inc.  See MIT-LICENSE for license information.
# Visit http://www.zerigo.com/docs/managed-dns for updates and documentation.

require 'rubygems'
require 'resource_party'

module ResourceParty
  class ValidationError < RuntimeError; end
  class Base
    # add parsing for the x-query-count header
    def self.all(query = {})
      response = self.get("/#{self.route}.xml", :query => query)
      handle_errors(response)
      items = response.values.first
      i = items.map{|hash| self.from_xml hash }
      
      if response.headers['x-query-count']
        i.instance_eval "def last_count ; #{response.headers['x-query-count'][0].to_i} ; end"
      end
      i
    end
    
    private
    
    # fix a couple of issues with newer versions of httparty
    # also add error parsing
    def self.handle_not_found(response)
      raise RecordNotFound.new(response.body) if response.code.to_i == 404
    end
    
    def self.handle_errors(response)
      case response.code.to_i
      when 200, 201 : return
      when 422
        raise ValidationError.new(Crack::XML.parse(response.body)['errors']['error'].to_a)
      else
        raise ServerError.new(response.body)
      end
    end
    
    # remove dependency on Hash#from_xml
    def self.handle_response(response)
      # this did return nil, but true makes more sense as a 200 response + blank response generally indicates success
      return true if response.body.blank? || response.body == ' '
      self.from_xml response.values.first
    end
  
  end
end

module Zerigo
  module DNS
    class Base < ResourceParty::Base
      base_uri 'http://ns.zerigo.com/api/1.1/'
      
      def self.user ; @@user ||= nil ; end
      def self.api_key ; @@api_key ||= nil ; end
      def self.user=(u)
        @@user = u
        basic_auth user, api_key
      end
      def self.api_key=(k)
        @@api_key = k
        basic_auth user, api_key
      end
    end
    
    class Zone < Base
      route_for 'zones'
      resource_for 'zone'
    end
    
    class Host < Base
      route_for 'hosts'
      resource_for 'host'
    end
  end
end
