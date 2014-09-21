# encoding: ascii-8bit

# The storage implementation supports different backends, which inherit from
# Storage::StoreBase and implement the same interface.
# Each backend returns Storage::Models objects to easily access helper methods and metadata.
#
# The most stable backend is Backends::SequelStore, which uses sequel and can use all
# kinds of SQL database backends.
module Bitcoin::Storage

  autoload :Models, 'bitcoin/storage/models'

  @log = Bitcoin::Logger.create(:storage)
  def self.log; @log; end

  BACKENDS = [:dummy, :sequel, :utxo, :spv]
  BACKENDS.each do |name|
    module_eval <<-EOS
      def self.#{name} config, *args
        Backends.const_get("#{name.capitalize}Store").new(config, *args)
      end
    EOS
  end

  module Backends

    BACKENDS.each {|b| autoload("#{b.to_s.capitalize}Store", "bitcoin/storage/#{b}/#{b}_store.rb") }

    # Base class for storage backends.
    # Every backend must overwrite the "Not implemented" methods
    # and provide an implementation specific to the storage.
    # Also, before returning the objects, they should be wrapped
    # inside the appropriate Bitcoin::Storage::Models class.
    class StoreBase

      # main branch (longest valid chain)
      MAIN = 0

      # side branch (connected, valid, but too short)
      SIDE = 1

      # orphan branch (not connected to main branch / genesis block)
      ORPHAN = 2

      # possible script types
      SCRIPT_TYPES = [:unknown, :pubkey, :pubkey_hash, :multisig, :script_hash, :op_return]
      if Bitcoin.namecoin?
        [:name_new, :name_firstupdate, :name_update].each {|n| SCRIPT_TYPES << n }
      end

      # possible address types
      ADDRESS_TYPES = [:pubkey_hash, :script_hash]

      DEFAULT_CONFIG = {}

      attr_reader :log

      attr_accessor :config

      def initialize(config = {}, getblocks_callback = nil)
        # merge all the configuration defaults, keeping the most specific ones.
        store_ancestors = self.class.ancestors.select {|a| a.name =~ /StoreBase$/ }.reverse
        base = store_ancestors.reduce(store_ancestors[0]::DEFAULT_CONFIG) do |config, ancestor|
          config.merge(ancestor::DEFAULT_CONFIG)
        end
        @config = base.merge(self.class::DEFAULT_CONFIG).merge(config)
        @log    = config[:log] || Bitcoin::Storage.log
        @log.level = @config[:log_level]  if @config[:log_level]

        init_store_connection
        @getblocks_callback = getblocks_callback
        @checkpoints = Bitcoin.network[:checkpoints] || {}
        @notifiers = {}
      end

      # name of the storage backend currently in use ("sequel" or "utxo")
      def backend_name
        self.class.name.split("::")[-1].split("Store")[0].downcase
      end

      # reset the store; delete all data
      def reset
        not_implemented
      end

      # check data consistency of the top +count+ blocks.
      def check_consistency count
        not_implemented
      end

      def add_watched_address addr, height = 0
        push_notification(:watch_address, [addr, height])
      end

      # handle a new block incoming from the network
      def new_block blk
        time = Time.now
        res = store_block(blk)
        # TODO: show tx/hashes count correctly
        log.info { "block #{blk.hash} " +
          "[#{res[0]}, #{['main', 'side', 'orphan'][res[1]]}] " +
          "(#{"%.6fs, %3dtx, %.3fkb" % [(Time.now - time), (blk.respond_to?(:hashes) ? blk.hashes.count : blk.tx.count), blk.to_payload.bytesize.to_f/1000]})" }  if res && res[1]
        res
#      rescue
#        [0, 0]
      end

      # store given block +blk+.
      # determine branch/chain and dept of block. trigger reorg if side branch becomes longer
      # than current main chain and connect orpans.
      def store_block blk
        log.debug { "new block #{blk.hash}" }

        # ignore block if we already have it
        existing = block(blk.hash)
        if existing && existing.chain == MAIN
          log.debug { "=> exists (#{existing.height}, #{existing.chain})" }
          return [existing.height]
        end

        # find the prev_block this block links to
        prev_block = block(blk.prev_block_hash.reverse_hth)

        # validate block syntax
        unless @config[:skip_validation]
          validator = blk.validator(self, prev_block)
          validator.validate(rules: [:syntax], raise_errors: true)
        end

        # when there is no prev_block, this block is either the genesis or an orphan
        if !prev_block || prev_block.chain == ORPHAN
          if blk.hash == Bitcoin.network[:genesis_hash]
            log.debug { "=> genesis (0)" }
            return persist_block(blk, MAIN, 0)
          else
            height = prev_block ? prev_block.height + 1 : 0
            log.debug { "=> orphan (#{height})" }
            return [0, 2]  unless (in_sync? || Bitcoin.network_name =~ /testnet/)
            return persist_block(blk, ORPHAN, height)
          end
        end

        height = prev_block.height + 1

        # if there is a checkpoint at this height, make sure the block hash matches
        checkpoint = @checkpoints[height]
        if checkpoint && blk.hash != checkpoint
          log.warn "Block #{height} doesn't match checkpoint #{checkpoint}"
          exit  if height > height # TODO: handle checkpoint mismatch properly
        end

        if prev_block.chain == MAIN
          # if prev_block is the current head of the main chain, this block becomes the new one
          if prev_block == head
            log.debug { "=> main (#{height})" }
            if !@config[:skip_validation] && ( !@checkpoints.any? || height > @checkpoints.keys.last )
              if self.class.name =~ /UtxoStore/
                @config[:utxo_cache] = 0
                @config[:block_cache] = 120
              end
              validator.validate(rules: [:context], raise_errors: true)
            end

            res = persist_block(blk, MAIN, height, prev_block.work)
            push_notification(:block, [blk, *res])
            return res
          # if prev_block is below head in the main chain, this block starts a new side chain
          else
            log.debug { "=> side (#{height})" }
            return persist_block(blk, SIDE, height, prev_block.work)
          end
        # prev_block is in a side chain
        else
          # if main chain is still longer, new block extends the side chain
          if prev_block.work + blk.block_work <= head.work
            log.debug { "=> side (#{height})" }
            return persist_block(blk, SIDE, height, prev_block.work)
          # if side chain is now longer than main, trigger a reorg
          else
            log.debug { "=> reorg" }
            new_main, new_side = [], []
            # walk down the side chain until we find the fork block (the first in the main chain)
            # these blocks will become the new main chain
            fork_block = prev_block
            while fork_block.chain != MAIN
              new_main << fork_block.hash
              fork_block = fork_block.prev_block
            end
            # walk up the main chain starting with the fork block
            # these blocks will become the new side chain
            b = fork_block
            while b = b.next_block
              new_side << b.hash
            end
            log.debug { "new main: #{new_main.inspect}" }
            log.debug { "new side: #{new_side.inspect}" }

            # switch side and main chain
            reorg(new_side.reverse, new_main.reverse)
            push_notification(:reorg, [ new_main.reverse, new_side ])

            # now the current block simply extends the new main chain
            res = persist_block(blk, MAIN, height, prev_block.work)
            push_notification(:block, [blk, *res])
            return res
          end
        end
      end

      # persist given block +blk+ to storage.
      def persist_block(blk)
        not_implemented
      end

      # update +attrs+ for block with given +hash+.
      # typically used to update the chain value during reorg.
      def update_block(hash, attrs)
        not_implemented
      end

      def new_tx(tx)
        store_tx(tx)
      end

      # store given +tx+
      def store_tx(tx, validate = true)
        not_implemented
      end

      # check if block with given +blk_hash+ is already stored
      def has_block(blk_hash)
        not_implemented
      end

      # check if tx with given +tx_hash+ is already stored
      def has_tx(tx_hash)
        not_implemented
      end

      # get the hash of the leading block
      def head
        not_implemented
      end
      alias :get_head :head

      # get hash of the head block
      def head_hash
        head.hash
      end
      alias :get_head_hash :head_hash

      # return height of the head block
      def height
        not_implemented
      end
      alias :get_depth :height

      # compute blockchain locator
      def locator pointer = head
        if @locator
          locator, head = @locator
          if head == pointer
            return locator
          end
        end

        return [("\x00"*32).hth]  if height == -1
        locator, step, orig_pointer = [], 1, pointer
        while pointer && pointer.hash != Bitcoin::network[:genesis_hash]
          locator << pointer.hash
          height = pointer.height - step
          break unless height > 0
          prev_block = block_at_height(height) # TODO
          break unless prev_block
          pointer = prev_block
          step *= 2  if locator.size > 10
        end
        locator << Bitcoin::network[:genesis_hash]
        @locator = [locator, orig_pointer]
        locator
      end
      alias :get_locator :locator

      # get block with given +blk_hash+
      def block(blk_hash)
        not_implemented
      end
      alias :get_block :block

      # get block at given +height+ in main chain
      def block_at_height(height)
        not_implemented
      end
      alias :get_block_by_depth :block_at_height

      # get block with given +prev_hash+
      def block_by_prev_hash(prev_hash)
        not_implemented
      end
      alias :get_block_by_prev_hash :block_by_prev_hash

      # get block that includes tx with given +tx_hash+
      def block_by_tx(tx_hash)
        not_implemented
      end
      alias :get_block_by_tx :block_by_tx

      # get block by given +block_id+
      def block_by_id(block_id)
        not_implemented
      end
      alias :get_block_by_id :block_by_id

      # get block id in main chain by given +tx_id+
      def block_id_for_tx_id(tx_id)
        tx_by_id(tx_id).blk_id rescue nil # tx.blk_id is always in main chain
      end
      alias :get_block_id_for_tx_id :block_id_for_tx_id

      # get corresponding txin for the txout in
      # transaction +tx_hash+ with index +txout_idx+
      def txin_for_txout(tx_hash, txout_idx)
        not_implemented
      end
      alias :get_txin_for_txout :txin_for_txout

      # get an array of corresponding txins for provided +txouts+
      # txouts = [tx_hash, tx_idx]
      # can be overwritten by specific storage for opimization
      def txins_for_txouts(txouts)
        txouts.map{|tx_hash, tx_idx| txin_for_txout(tx_hash, tx_idx) }.compact
      end
      alias :get_txins_for_txouts :txins_for_txouts

      # get tx with given +tx_hash+
      def tx(tx_hash)
        not_implemented
      end
      alias :get_tx :tx

      # get more than one tx by +tx_hashes+, returns an array
      # can be reimplemented by specific storage for optimization
      def txs(tx_hashes)
        tx_hashes.map {|h| tx(h)}.compact
      end
      alias :get_txs :txs

      # get tx with given +tx_id+
      def tx_by_id(tx_id)
        not_implemented
      end
      alias :get_tx_by_id :tx_by_id

      # Grab the position of a tx in a given block
      def idx_from_tx_hash(tx_hash)
        not_implemented
      end
      alias :get_idx_from_tx_hash :idx_from_tx_hash

      # collect all txouts containing the
      # given +script+
      def txouts_for_pk_script(script)
        not_implemented
      end
      alias :get_txouts_for_pk_script :txouts_for_pk_script

      # collect all txouts containing a
      # standard tx to given +address+
      def txouts_for_address(address, unconfirmed = false)
        hash160 = Bitcoin.hash160_from_address(address)
        type = Bitcoin.address_type(address)
        txouts_for_hash160(hash160, type, unconfirmed)
      end
      alias :get_txouts_for_address :txouts_for_address

      # collect all unspent txouts containing a
      # standard tx to given +address+
      def unspent_txouts_for_address(address, unconfirmed = false)
        txouts = self.txouts_for_address(address, unconfirmed)
        txouts.select! {|t| ! t.next_in }
        txouts
      end
      alias :get_unspent_txouts_for_address :unspent_txouts_for_address

      # get balance for given +hash160+
      def balance(hash160_or_addr, unconfirmed = false)
        if Bitcoin.valid_address?(hash160_or_addr)
          txouts = txouts_for_address(hash160_or_addr)
        else
          txouts = txouts_for_hash160(hash160_or_addr, :pubkey_hash, unconfirmed)
        end
        unspent = txouts.select {|o| o.next_in.nil?}
        unspent.map(&:value).inject {|a,b| a+=b; a} || 0
      rescue
        nil
      end
      alias :get_balance :balance

      # parse script and collect address/txout mappings to index
      def parse_script txout, i, tx_hash = "", tx_idx
        addrs, names = [], []

        script = Bitcoin::Script.new(txout.pk_script) rescue nil
        if script
          if script.is_hash160? || script.is_pubkey? || script.is_p2sh?
            addrs << [i, script.get_address]
          elsif script.is_multisig?
            script.get_multisig_addresses.map do |address|
              addrs << [i, address]  if address
            end
          elsif Bitcoin.namecoin? && script.is_namecoin?
            addrs << [i, script.get_address]
            names << [i, script]
          elsif script.is_op_return?
            log.info { "Ignoring OP_RETURN script: #{script.get_op_return_data}" }
          else
            log.info { "Unknown script type in txout #{tx_hash}:#{tx_idx}" }
            log.debug { script.to_string }
          end
          script_type = SCRIPT_TYPES.index(script.type)
        else
          log.error { "Error parsing script #{tx_hash}:#{tx_idx}" }
          script_type = SCRIPT_TYPES.index(:unknown)
        end
        [script_type, addrs, names]
      end

      def rescan
        not_implemented
      end

      def check_consistency *a
        log.warn { "Consistency check not implemented" }
      end

      # import satoshi bitcoind blk0001.dat blockchain file
      def import filename, max_height = nil
        if File.file?(filename)
          log.info { "Importing #{filename}" }
          File.open(filename) do |file|
            until file.eof?
              magic = file.read(4)

              # bitcoind pads the ends of the block files so that it doesn't
              # have to reallocate space on every new block.
              break if magic == "\0\0\0\0"
              raise "invalid network magic" unless Bitcoin.network[:magic_head] == magic

              size = file.read(4).unpack("L")[0]
              buf = file.read(size)
              blk = Bitcoin::P::Block.new(buf)

              (txs = blk.tx; blk = Bitcoin::P::MerkleBlock.from_block(blk))  if is_spv?
              height, chain = new_block(blk)
              txs.each {|t| store_tx(t) }  if is_spv?

              push_notification(:block, [blk, height, chain])
              break  if max_height && height >= max_height
            end
          end
        elsif File.directory?(filename)
          Dir.entries(filename).sort.each do |file|
            next  unless file =~ /^blk.*?\.dat$/
            import(File.join(filename, file), max_height)
          end
        else
          raise "Import dir/file #{filename} not found"
        end
      end

      def in_sync?
        in_sync = (head && (Time.now - head.time).to_i < 3600)
        log.info { "Storage in sync with blockchain." }  if in_sync && !@in_sync
        @in_sync = in_sync
      end

      def push_notification channel, message
        @notifiers[channel.to_sym].push(message)  if @notifiers[channel.to_sym]
      end

      def subscribe channel
        @notifiers[channel.to_sym] ||= EM::Channel.new
        @notifiers[channel.to_sym].subscribe {|*data| yield(*data) }
      end

      def storage_mode
        :full
      end

      def is_utxo?; storage_mode == :utxo; end
      def is_full?; storage_mode == :full; end
      def is_spv?; storage_mode == :spv; end

      # called from abstract methods when their implementation is missing
      def not_implemented
        method = caller[0].scan(/:in\s`(.*?)'/)[0][0]
        raise "Method '#{method}' not implemented in '#{backend_name}' backend."
      end

    end

    class SequelStoreBase < StoreBase

      DEFAULT_CONFIG = {
        sqlite_pragmas: {
          # journal_mode pragma
          journal_mode: false,
          # synchronous pragma
          synchronous: false,
          # cache_size pragma
          # positive specifies number of cache pages to use,
          # negative specifies cache size in kilobytes.
          cache_size: -200_000,
        }
      }

      SEQUEL_ADAPTERS = { sqlite: "sqlite3", postgres: "pg", mysql: "mysql" }

      # table names to be used in the database
      # TODO: make this configurable
      TABLES= {
        # used by both stores
        blocks: :blocks,
        outputs: :outputs,  # this is the only one with different columns in the two stores
        addresses: :addresses,
        address_outputs: :address_outputs,
        names: :names,

        # used only by sequel store
        transactions: :transactions,
        block_transactions: :block_transactions,
        inputs: :inputs
      }

      # setup the DB connection, according to given config
      def init_store_connection
        return  unless (self.is_a?(SequelStore) || self.is_a?(UtxoStore)) && @config[:db]
        @config[:db].sub!("~", ENV["HOME"])
        @config[:db].sub!("<network>", Bitcoin.network_name.to_s)
        adapter = SEQUEL_ADAPTERS[@config[:db].split(":").first] rescue nil
        Bitcoin.require_dependency(adapter, gem: adapter)  if adapter
        connect
      end

      # connect to database
      def connect
        Sequel.extension(:core_extensions, :sequel_3_dataset_methods)
        @db = Sequel.connect(@config[:db].sub("~", ENV["HOME"]))
        @db.extend_datasets(Sequel::Sequel3DatasetMethods)
        TABLES.each {|k, v| @db.instance_eval "def #{k}; self[:#{v}]; end" }
        sqlite_pragmas; migrate; check_metadata
        log.info { "opened #{backend_name} store #{@db.uri}" }
      end

      # delete all tables (so they will be created fresh) and reset cached head block
      def reset
        TABLES.values.each.each {|table| db[table].delete rescue nil }
        @head = nil
      end

      # check if schema is up to date and migrate to current version if necessary
      def migrate
        migrations_path = File.join(File.dirname(__FILE__), "#{backend_name}/migrations")
        Sequel.extension :migration
        unless Sequel::Migrator.is_current?(@db, migrations_path)
          store = self
          @db.instance_eval do
            @store = store
            @log = store.log
            @tables = store.class::TABLES
          end
          Sequel::Migrator.run(@db, migrations_path)
          unless (v = @db[:schema_info].first) && v[:magic] && v[:backend]
            @db[:schema_info].update(
              magic: Bitcoin.network[:magic_head].hth, backend: backend_name)
          end
        end
      end

      # check that database network magic and backend match the ones we are using
      def check_metadata
        version = @db[:schema_info].first
        unless version[:magic] == Bitcoin.network[:magic_head].hth
          name = Bitcoin::NETWORKS.find{|n,d| d[:magic_head].hth == version[:magic]}[0]
          raise "Error: DB #{@db.url} was created for '#{name}' network!"
        end
        unless version[:backend] == backend_name
          if version[:backend] == "sequel" && backend_name == "utxo"
            log.warn { "Note: The 'utxo' store is now the default backend.
            To keep using the full storage, change the configuration to use storage: 'sequel::#{@db.url}'.
            To use the new storage backend, delete or move #{@db.url}, or specify a different database path in the config." }
          end
          raise "Error: DB #{@db.url} was created for '#{version[:backend]}' backend!"
        end
      end

      # set pragma options for sqlite (if it is sqlite)
      def sqlite_pragmas
        return  unless (@db.is_a?(Sequel::SQLite::Database) rescue false)
        @config[:sqlite_pragmas].each do |name, value|
          @db.pragma_set name, value
          log.debug { "set sqlite pragma #{name} to #{value}" }
        end
      end

    end

  end
end


# TODO: someday sequel will support #blob directly and #to_sequel_blob will be gone
class String; def blob; to_sequel_blob; end; end
