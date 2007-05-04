require 'rexml/document'

class Ping < ActiveRecord::Base
  belongs_to :article

  class Pinger
    attr_accessor :article
    attr_accessor :blog

    def send_pingback_or_trackback
      @logger = RAILS_DEFAULT_LOGGER
      begin
        @logger.info "About to get resource: #{ping.url}"
        uri = URI.parse(ping.url)
        @response = Net::HTTP.get_response(uri)
        #@logger.info "\nAbout to get resource: #{uri}"
        #test = Resolv.getaddress(uri.host)
        #conn = Net::HTTP.new(uri.host, uri.port)
        #@response = conn.get(uri.path)
        @logger.info "Got resource for #{uri}"
        send_pingback or send_trackback
        @logger.info "Done pinger for #{uri}"
      rescue Timeout::Error => err
        @logger.info "Sending pingback or trackback timed out"
        return
      rescue => err
        @logger.info "Sending pingback or trackback failed with error: #{err}"
      end
    end

    private

    def pingback_url
      if @response["X-Pingback"]
        @response["X-Pingback"]
      elsif
        response.body =~ /<link rel="pingback" href="([^"]+)" ?\/?>/
        $1
      else
        nil
      end
    end

    def origin_url
      @origin_url
    end

    def response
      @response
    end

    def ping
      @ping
    end

    def send_xml_rpc(*args)
      ping.send(:send_xml_rpc, *args)
    end

    def trackback_url
      rdfs = response.body.scan(/<rdf:RDF.*?<\/rdf:RDF>/m)
      rdfs.each do |rdf|
        xml = REXML::Document.new(rdf)
        xml.elements.each("//rdf:Description") do |desc|
          if rdfs.size == 1 || desc.attributes["dc:identifier"] == ping.url
            return desc.attributes["trackback:ping"]
          end
        end
      end
      # Didn't find a trackback url, so fall back to the url itself.
      @ping.url
    end

    def send_pingback
      if pingback_url
        @logger.info "Pinger.send_pingback: #{pingback_url}"
        send_xml_rpc(pingback_url, "pingback.ping", origin_url, ping.url)
        return true
      else
        return false
      end
    end

    def send_trackback
      @logger.info "Pinger.send_trackback: #{trackback_url}"
      ping.send_trackback(trackback_url, origin_url)
    end

    def initialize(origin_url, ping)
      @origin_url = origin_url
      @ping       = ping
      # Make sure these are fetched now for thread safety purposes.
      self.article = ping.article
      self.blog    = article.blog
    end
  end

  def send_pingback_or_trackback(origin_url)
    t = Thread.start(Pinger.new(origin_url, self)) do |pinger|
      pinger.send_pingback_or_trackback
    end
    logger.info "About to wait for thread" if defined? $TESTING
    t.join if defined? $TESTING
  end

  def send_trackback(trackback_url, origin_url)
    trackback_uri = URI.parse(trackback_url)

    post = "title=#{CGI.escape(article.title)}"
    post << "&excerpt=#{CGI.escape(article.html(:body).strip_html[0..254])}"
    post << "&url=#{origin_url}"
    post << "&blog_name=#{CGI.escape(article.blog.blog_name)}"

    Net::HTTP.start(trackback_uri.host, trackback_uri.port) do |http|
      path = trackback_uri.path
      path += "?#{trackback_uri.query}" if trackback_uri.query
      http.post(path, post, 'Content-type' => 'application/x-www-form-urlencoded; charset=utf-8')
    end
  end

  def send_weblogupdatesping(server_url, origin_url)
    send_xml_rpc(self.url, "weblogUpdates.ping", article.blog.blog_name,
                 server_url, origin_url)
  end

  protected

  def send_xml_rpc(xml_rpc_url, name, *args)
    begin
      server = XMLRPC::Client.new2(URI.parse(xml_rpc_url).to_s)

      begin
        result = server.call(name, *args)
      rescue XMLRPC::FaultException => e
        logger.error(e)
      end
    rescue Exception => e
      logger.error(e)
    end
  end
end
