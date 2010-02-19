module CouchRest
  class Database
	  # PUT an attachment directly to CouchDB
    def put_attachment(doc, name, file, options = {})
      docid = escape_docid(doc['_id'])
			# name = CGI.escape(name) # url_for_attachment CGI escapes; doing twice breaks stuff
      uri = url_for_attachment(doc, name)
      JSON.parse(HttpAbstraction.put(uri, file, options))
    end
	end
end