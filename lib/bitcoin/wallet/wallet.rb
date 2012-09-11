Bitcoin.require_dependency :eventmachine, exit: false

require "bitcoin/electrum/client"

# The wallet implementation consists of several concepts:
# Wallet::             the high-level API used to manage a wallet
# SimpleKeyStore::     key store to manage keys/addresses/labels
# SimpleCoinSelector:: coin selector to find unspent outputs to use when creating tx
module Bitcoin::Wallet

  # A wallet manages a set of keys (through a +keystore+), can
  # list transactions/balances for those keys (using a Storage backend for
  # blockchain data).
  # It can also create transactions with various kinds of outputs and
  # connect with a CommandClient to relay those transactions through a node.
  #
  # TODO: new tx notification, keygenerators, keystore cleanup
  class Wallet

    include Bitcoin::Builder

    # the keystore (SimpleKeyStore) managing keys/addresses/labels
    attr_reader :keystore

    # the Storage which holds the blockchain
    attr_reader :storage

    attr_reader :electrum
    attr_reader :txouts

    attr_reader :height

    # open wallet with given +storage+ Storage backend, +keystore+ SimpleKeyStore
    # and +selector+ SimpleCoinSelector
    def initialize storage, keystore, selector
      @txouts = {}
      @keystore = keystore
      @selector = selector
      @callbacks = {}
      @height = 0
      connect_node  #if defined?(EM) && EM.reactor_running?
    end

    def connected &block
      @callbacks[:connected] = block
    end

    def connect_node
      EM.run do
        @electrum = ElectrumClient.connect
        @electrum.connected do |e|
          e.request("blockchain.numblocks.subscribe") do |num|
            @height = num
          end
          @keystore.keys.map do |key|
            e.request("blockchain.address.get_history", key[:addr]) do |txouts|
              @txouts[key[:addr]] = txouts
            end
            e.on("blockchain.address.subscribe", key[:addr]) do |*a|
              p a
            end
          end
        end
        EM.defer do
          while @txouts.keys.size < @keystore.keys.size
            # p @txouts.keys.size
            sleep 0.1
          end
          @callbacks[:connected].call
        end
      end
    end

    def log
      return @log  if @log
      @log = Bitcoin::Logger.create("wallet")
      @log.level = :debug
      @log
    end

    # call the callback specified by +name+ passing in +args+
    def callback name, *args
      cb = @callbacks[name.to_sym]
      return  unless cb
      log.debug { "callback: #{name}" }
      cb.call(*args)
    end

    # register callback methods
    def method_missing(name, *args, &block)
      if name =~ /^on_/
        @callbacks[name.to_s.split("on_")[1].to_sym] = block
        log.debug { "callback #{name} registered" }
      else
        super(name, *args)
      end
    end

    # get all Storage::Models::TxOut concerning any address from this wallet
    def get_txouts(unconfirmed = false)
      txouts = @keystore.keys.map{|k| @txouts[k[:addr]] }.flatten
      unconfirmed ? txouts : txouts.select {|o| o['height']}
    end

    # get total balance for all addresses in this wallet
    def get_balance(unconfirmed = false)
      values = get_txouts.map{|o| o['value'] }
      ([0] + values).inject(:+)
    end

    # list all addresses in this wallet
    def addrs
      @keystore.keys.map{|k| k[:addr]}
    end

    # add +key+ to wallet
    def add_key key
      @keystore.add_key(key)
    end

    # set label for key +old+ to +new+
    def label old, new
      @keystore.label_key(old, new)
    end

    # set +flag+ for key +name+ to +value+
    def flag name, flag, value
      @keystore.flag_key(name, flag, value)
    end

    # list all keys along with their balances
    def list
      @keystore.keys.map do |key|
        [key, ([0]+@txouts[key[:addr]].map{|t| t['value']}).inject(:+)]
      end
    end

    # create new key and return its address
    def get_new_addr
      @keystore.new_key.addr
    end

    # get SimpleCoinSelector with txouts for this wallet
    def get_selector
      @selector.new(get_txouts)
    end

    # create a transaction with given +outputs+, +fee+ and +change_policy+.
    #
    # outputs are of the form
    #  [<type>, <recipients>, <value>]
    # examples:
    #  [:address, <addr>, <value>]
    #  [:multisig, 2, 3, <addr>, <addr>, <addr>, <value>]
    #
    # inputs are selected automatically by the SimpleCoinSelector.
    # 
    # change_policy controls where the change_output is spent to.
    # see #get_change_addr
    def new_tx outputs, fee = 0, change_policy = :back
      output_value = outputs.map{|o|o[-1]}.inject(:+)
      prev_outs = get_selector.select(output_value + fee)
      return nil  if !prev_outs
      input_value = prev_outs.map{|o|o['value']}.inject(:+)
      return nil  unless input_value >= (output_value + fee)
      tx = tx do |t|
        outputs.each do |type, *addrs, value|
          t.output do |o|
            o.value value
            o.script do |s|
              s.type type
              s.recipient *addrs
            end
          end
        end

        change_value = input_value - output_value - fee
        if change_value > 0
          change_addr = @keystore.keys.sample[:addr]
          #get_change_addr(change_policy, prev_outs.sample.get_address)
          t.output do |o|
            o.value change_value
            o.script do |s|
              s.type :address
              s.recipient change_addr
            end
          end
        end

        prev_outs.each_with_index do |prev_out, idx|
          t.input do |i|
            # prev_tx = prev_out.get_tx
            i.prev_out prev_out['tx_hash']
            i.prev_out_index prev_out['index']
            script = Bitcoin::Script.new([prev_out['raw_output_script']].pack("H*"))
            i.pk_script script.raw
            i.signature_key(@keystore.key(script.get_address)[:key])
          end
        end
      end
      # TODO: spend multisig outputs again
      # TODO: verify signatures
      Bitcoin::Protocol::Tx.new(tx.to_payload)
    end

    protected

    # get address to send change output to.
    # +policy+ controls which address is chosen:
    # first:: send to the first key in the wallets keystore
    # random:: send to a random key from the wallets keystore
    # new:: send to a new key generated in the wallets keystore
    # back:: send to the address given as +in_addr+
    def get_change_addr(policy, in_addr)
      case policy
      when :first
        @keystore.keys[0].addr
      when :random
        @keystore.keys.sample.addr
      when :new
        @keystore.new_key.addr
      when :back
        in_addr
      else
        policy
      end
    end

  end

end
