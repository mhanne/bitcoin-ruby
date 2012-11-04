require 'bitcoin'
require 'eventmachine'
require 'evma_httpserver'
require 'json'

module Bitcoin::Electrum

  class Server

    VERSION = "0.4"

    attr_reader :node, :log, :config, :banner, :peers

    def initialize node, config
      @node = node
      @config = config[:electrum]
      @log = Bitcoin::Logger.create(:electrum, config[:log][:electrum])
      @banner = File.read("/etc/electrum.banner") rescue ""
      @banner += "\n===========\nbitcoin-ruby v#{Bitcoin::VERSION}" +
        " - http://github.com/lian/bitcoin-ruby"
      @peers = {}
      run
    end

    def run
      EM.connect("irc.freenode.net", 6667, IrcConnection, self)  if @config[:nick]
      host = @config[:listen]
      %w(tcp ssl http https).each do |c|
        next  unless port = @config["#{c}_port".to_sym]
        EM.start_server(host, port, Bitcoin::Electrum.const_get("#{c.upcase}Connection"), self)
        log.info { "Electrum #{c} server listening on #{host}:#{port}" }
      end
      EM.add_periodic_timer(HTTPSession::TIMEOUT) { HTTPSession.timeout }
    end

  end

  class IrcConnection < EM::Connection

    CHANNEL = "#electrum"

    def initialize server
      @server = server
    end

    def config; @server.config; end

    def get_name
      name = "v#{Server::VERSION}"
      name << " t#{config[:tcp_port]}"  if config[:tcp_port]
      name << " h#{config[:http_port]}"  if config[:http_port]
      name << " s#{config[:ssl_port]}"  if config[:ssl_port]
      name << " g#{config[:https_port]}"  if config[:https_port]
    end

    def post_init
      send_data("USER electrum 0 * : #{config[:host] || config[:listen]} #{get_name} \n")
      send_data("NICK E_#{config[:nick] || (0...10).map{65.+(rand(26)).chr}.join }\n")
      send_data("JOIN #{CHANNEL}\n")
    end

    def receive_data data
      data.split("\r\n").each do |line|
        @server.log.debug { line }
        begin
          line = line.split(" ")
          if line.include?("PING")
            send_data("NAMES #{CHANNEL}\n")
          elsif line.include?("353") # /names
            line[line.index("353")..-1].each {|l| send_data("WHO #{l}\n")  if l =~ /^E_/ }
          elsif line.include?("352") # /who
            i = line.index("352")
            ip = Socket.getaddrinfo(line[i+4], nil)[0][2]
            name = line[i+6]
            host = line[i+9]
            ports = line[i+10..-1]
            @server.peers[name] = [ip, host, ports]
          end
        rescue
          @server.log.warn { "Error handling line: #{$!.inspect}" }
        end
      end
    end
  end

  module ConnectionHandler

    def store; @server.node.store; end
    def log; @log ||= Bitcoin::Logger::LogWrapper.new("#{peer.join(':')}", @server.log); end
    def peer; Socket.unpack_sockaddr_in(get_peername).reverse; end

    def client_connected
      @block_channel = @server.node.notifiers[:block].subscribe do |block, depth|
        if @subscribed_numblocks
          respond({}, method: "blockchain.numblocks.subscribe", params: [depth])
        end
        if @subscribed_headers
          respond({}, method: "blockchain.headers.subscribe", params: [get_header])
        end
        block.tx.each {|tx| check_tx(tx, block.hash) }
      end
      log.info { "client connected" }
    end

    def client_disconnected
      @server.node.notifiers[:block].unsubscribe(@block_channel)  if @block_channel
      log.info { "client disconnected" }
    end

    def handle_request pkt
      log.debug { "req##{pkt['id']} #{pkt['method']}(#{pkt['params'].inspect})" }
      case pkt['method']
      when /version/
        respond(pkt, result: Server::VERSION)
      when /banner/
        respond(pkt, result: @server.banner)
      when /blockchain.numblocks.subscribe/
        @subscribed_numblocks = true
        respond(pkt, result: store.get_depth)
      when /blockchain.headers.subscribe/
        @subscribed_headers = true
        respond(pkt, result: get_header)
      when /blockchain.address.get_history/
        get_history(pkt)
      when /server.peers/
        respond(pkt, result: @server.peers.values)
      when /blockchain.address.subscribe/
        subscribe_address(pkt)
      when /blockchain.transaction.get_merkle/
        get_merkle(pkt)
      when /blockchain.block.get_chunk/
        get_chunk(pkt)
      when /blockchain.transaction.broadcast/
        tx = Bitcoin::P::Tx.new(pkt['params'].pack("H*"))
        if @server.node.relay_tx(tx)
          respond(pkt, result: tx.hash)
        else
          respond(pkt, error: "error broadcasting tx")
        end
      else
        respond(pkt, error: "Method #{pkt['method']} not supported.")
      end
    rescue
      respond(pkt, error: "error: #{$!.message}")
      log.warn { "error handling request: #{$!.inspect}" }
    end

    def get_history pkt
      txouts = []
      store.get_txouts_for_address(pkt['params'][0], true).each do |txout|
        tx = txout.get_tx
        block = store.db[:blk][id: tx.blk_id]
        txouts << {
          block_hash: (block ? block[:hash].hth : "mempool:#{tx.id}"),
          tx_hash: tx.hash,
          index: tx.out.index(txout),
          is_input: 0,
          outputs: tx.out.map(&:get_addresses).flatten,
          inputs: tx.in.map(&:get_prev_out).map(&:get_addresses).flatten,
          timestamp: (block ? block[:time] : 0),
          value: txout.value,
          height: (block ? block[:depth] : 0),
          raw_output_script: txout.pk_script.unpack("H*")[0] }

        next  unless txin = txout.get_next_in
        txouts[-1].delete(:raw_output_script)
        tx = txin.get_tx
        block = store.db[:blk][id: tx.blk_id]
        txouts << {
          block_hash: (block ? block[:hash].hth : "mempool:#{tx.id}"),
          tx_hash: tx.hash,
          index: tx.in.index(txin),
          is_input: 1,
          outputs: tx.out.map(&:get_address).flatten,
          inputs: tx.in.map(&:get_prev_out).map(&:get_addresses).flatten,
          timestamp: (block ? block[:time] : 0),
          value: 0 - txout.value,
          height: (block ? block[:depth] : 0) }
      end
      respond(pkt, result: txouts)
    end

    def subscribe_address pkt
      addr = pkt['params'][0]
      unless Bitcoin.valid_address?(addr)
        return respond(pkt, error: "Address #{addr} invalid.")
      end
      get_last_block(pkt)
      @subscribed_addresses << addr
    end

    def get_last_block pkt
      txouts = store.get_txouts_for_address(pkt['params'][0])
      if txouts.any?
        hash = txouts.map do |txout|
          block = store.db[:blk][id: txout.get_tx.blk_id]
          [block[:hash].unpack("H*"), block[:depth]]
        end.sort_by {|b| b[1]}.last[0]
      else
        hash = nil
      end
      respond(pkt, result: hash)
    end

    def get_header
      b = store.get_head
      { nonce: b.nonce,
        prev_block_hash: b.prev_block.reverse_hth,
        timestamp: b.time, merkle_root: b.mrkl_root.reverse_hth,
        block_height: b.depth, version: b.ver, bits: b.bits }
    end

    def get_merkle pkt
      hash = pkt['params'][0]
      @merkle_cache ||= {}
      unless @merkle_cache[hash]
        tx = store.get_tx(hash); block = tx.get_block
        @merkle_cache[hash] = { pos: block.tx.index(tx), block_height: block.depth,
          merkle: Bitcoin.hash_mrkl_branch(block.tx.map(&:hash), tx.hash) }
      end
      respond(pkt, result: @merkle_cache[hash])
    end

    def get_chunk pkt
      i = pkt['params'][0]
      r = store.db[:blk].where(chain: 0, depth: ((i * 2016)...((i + 1) * 2016))).map {|b|
        [ b[:version], b[:prev_hash].reverse, b[:mrkl_root].reverse,
          b[:time], b[:bits], b[:nonce] ].pack("Ia32a32III")
      }.join.unpack("H*")[0]
      respond(pkt, result: r)
    end

    def check_tx tx, block_hash = "mempool:x"
      prev_outs = tx.in[0].coinbase? ? [] : tx.in.map {|i|
        store.get_tx(i.prev_out.reverse_hth).out[i.prev_out_index] }
      (prev_outs + tx.out).compact.map {|o|
        Bitcoin::Script.new(o.pk_script).get_addresses & @subscribed_addresses
      }.flatten.uniq.each {|a|
        respond({}, method: "blockchain.address.subscribe", params: [a, block_hash]) }
    end

    def respond req, data
      data['id'] = req['id']  if req && req['id']
      data['method'] = req['method']  if req['method']
      log.debug { "res##{req['id']} #{data.inspect}" }
      send_response(data)
    end

  end

  class TCPConnection < EM::Connection

    include ConnectionHandler

    def initialize server
      @buf = BufferedTokenizer.new("\n")

      @server = server
      @subscribed_addresses = []
      @subscribed_numblocks = false
    end

    def post_init
      client_connected
    end

    def receive_data data
      @buf.extract(data).each do |packet|
        EM.defer { handle_request(JSON.load(packet)) }  if packet
      end
    end

    def send_response data
      send_data(data.to_json + "\n")
    end

    def unbind
      client_disconnected
    end

  end

  class SSLConnection < TCPConnection

    def post_init
      start_tls
      super
    end

    def ssl_handshake_completed
      log.info { "SSL connection established" }
    end

  end

  class HTTPSession

    include ConnectionHandler

    attr_accessor :sid, :responses, :last_active, :connection

    TIMEOUT = 30

    @@sessions = {}

    def initialize connection
      @sid = SecureRandom.uuid
      @@sessions[@sid] = self
      @connection = connection
      @responses = []
      @last_active = Time.now

      @server = connection.server
      @subscribed_addresses = []
      @subscribed_numblocks = false
      client_connected
    end

    def self.get id, connection
      session = @@sessions[id]  if id
      return new(connection)  unless session
      session.connection = connection
      session.last_active = Time.now
      session
    end

    def send_response data
      @responses << data
    end

    def respond!
      response = EM::DelegatedHttpResponse.new(connection)
      response.status = 200
      response.content_type 'application/json'
      response.content = @responses.to_json
      @responses = []
      response.headers["Set-Cookie"] = "SESSION=#{@sid}"
      response.send_response
    end

    def destroy
      client_disconnected
      @@sessions.delete(@sid)
    end

    def self.timeout
      @@sessions.each {|_, s| s.destroy  if s.last_active <= (Time.now - TIMEOUT) }
    end

    def get_peername
      @connection.get_peername
    end
  end

  class HTTPConnection < EM::Connection
    include EM::HttpServer

    attr_reader :server, :session

    def initialize server
      @server = server
    end

    def post_init
      super
      no_environment_strings
    end

    def process_http_request
      sid = (@http_cookie && @http_cookie =~ /SESSION=(.*)/) ? $1 : nil
      @session = HTTPSession.get(sid, self)
      JSON.load(@http_post_content).each {|r| session.handle_request(r) }  if @http_post_content
      session.respond!
    rescue
      log.warn { "error processing http request: #{$!.inspect}" }
    end

  end

  class HTTPSConnection < HTTPConnection

    def post_init
      start_tls
      super
    end

  end

end
