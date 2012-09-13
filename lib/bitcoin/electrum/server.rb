#!/usr/bin/env ruby
$:.unshift( File.expand_path("../../lib", __FILE__) )
require 'bitcoin'
require 'eventmachine'
require 'json'

module Bitcoin::Electrum

  class Server
    attr_reader :node, :log
    def initialize node, config
      @node = node
      @log = Bitcoin::Logger.create(:electrum, config[:log][:electrum])
      @log.level = :debug
      run(*config[:electrum])
    end
    def run host, port
      EM.start_server(host, port, ConnectionHandler, self)
      log.info { "Electrum server listening on #{host}:#{port}" }
    end
  end

  class ConnectionHandler < EM::Connection

    def initialize server
      @server = server
      @buf = BufferedTokenizer.new("\n")
      @port, @host = Socket.unpack_sockaddr_in(get_peername)
      @subscribed_addresses = []
      @subscribed_numblocks = false
      @block_channel = @server.node.notifiers[:block].subscribe do |block, depth|
        if @subscribed_numblocks
          respond({}, method: "blockchain.numblocks.subscribe", params: [depth])
        end
        block.tx.each {|tx| check_tx(tx, block.hash) }
      end
      # @tx_channel = @server.node.notifiers[:tx].subscribe {|tx| check_tx(tx) }
    end

    def store; @server.node.store; end
    def log; @log ||= Bitcoin::Logger::LogWrapper.new("#@host:#@port", @server.log); end

    def post_init
      log.info { "client connected" }
    end

    def receive_data data
      @buf.extract(data).each do |packet|
        EM.defer { handle_request(packet) }
      end
    end

    def handle_request packet
      pkt = JSON.load(packet)
      log.debug { "req##{pkt['id']} #{pkt['method']}(#{pkt['params'].inspect})" }
      case pkt['method']
      when /version/
        respond(pkt, result: "0.1")
      when /banner/
        respond(pkt, result: "bitcoin-ruby test")
      when /blockchain.numblocks.subscribe/
        @subscribed_numblocks = true
        respond(pkt, result: store.get_depth)
      when /blockchain.address.get_history/
        get_history(pkt)
      when /server.peers/
        respond(pkt, result: []) # TODO
      when /blockchain.address.subscribe/
        subscribe_address(pkt)
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

    def check_tx tx, block_hash = "mempool:x"
      prev_outs = tx.in[0].coinbase? ? [] : tx.in.map {|i|
        store.get_tx(i.prev_out.reverse_hth).out[i.prev_out_index] }
      (prev_outs + tx.out).map {|o|
        Bitcoin::Script.new(o.pk_script).get_addresses & @subscribed_addresses
      }.flatten.uniq.each {|a|
        respond({}, method: "blockchain.address.subscribe", params: [a, block_hash]) }
    end

    def respond req, data
      data['id'] = req['id']  if req['id']
      log.debug { "res##{req['id']} #{data.inspect}" }
      send_data(data.to_json + "\n")
    end

    def unbind
      @server.node.notifiers[:block].unsubscribe(@block_channel)  if @block_channel
      # @server.node.notifiers[:tx].unsubscribe(@tx_channel)  if @tx_channel
      log.info { "client disconnected" }
    end

  end

end

# if $0 == __FILE__
#   EM.run do
#     Bitcoin.network = :bitcoin
#     store = Bitcoin::Storage.sequel(db: "postgres:/bitcoin")
#     EM.start_server("127.0.0.1", 50001, Bitcoin::Electrum::Server, store)
#     p :running
#   end
# end
