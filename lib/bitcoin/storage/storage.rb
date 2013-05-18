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

  BACKENDS = [:dummy, :sequel, :utxo]
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
      SCRIPT_TYPES = [:unknown, :pubkey, :hash160, :multisig, :p2sh]
      if Bitcoin.namecoin?
        [:name_new, :name_firstupdate, :name_update].each {|n| SCRIPT_TYPES << n }
      end

      # name_new must have 12 confirmations before corresponding name_firstupdate is valid.
      NAMECOIN_FIRSTUPDATE_LIMIT = 12

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

      SEQUEL_ADAPTERS = { :sqlite => "sqlite3", :postgres => "pg", :mysql => "mysql" }

      attr_reader :log, :config

      attr_accessor :config

      def initialize(config = {}, getblocks_callback = nil)
        base = self.class.ancestors.select {|a| a.name =~ /StoreBase$/ }[0]::DEFAULT_CONFIG
        @config = base.merge(self.class::DEFAULT_CONFIG).merge(config)
        @log    = config[:log] || Bitcoin::Storage.log
        @log.level = @config[:log_level]  if @config[:log_level]
        init_sequel_store
        @getblocks_callback = getblocks_callback
        @checkpoints = Bitcoin.network[:checkpoints] || {}
      end

      def init_sequel_store
        return  unless (self.is_a?(SequelStore) || self.is_a?(UtxoStore)) && @config[:db]
        @config[:db].sub!("~", ENV["HOME"])
        @config[:db].sub!("<network>", Bitcoin.network_name.to_s)
        adapter = @config[:db].split(":").first
        name = @config[:db].split(":").first
        adapter = SEQUEL_ADAPTERS[name.to_sym] if name
        Bitcoin.require_dependency(adapter, gem: adapter)  if adapter
        connect
      end

      def connect
        Sequel.extension(:core_extensions, :sequel_3_dataset_methods)
        @db = Sequel.connect(@config[:db].sub("~", ENV["HOME"]))
        @db.extend_datasets(Sequel::Sequel3DatasetMethods)
        log.info { "opened database #{@db.uri}" }
        sqlite_pragmas
        migrate
      end

      def sqlite_pragmas
        return  unless (@db.is_a?(Sequel::SQLite::Database) rescue false)
        @config[:sqlite_pragmas].each do |name, value|
          @db.pragma_set name, value
          log.debug { "set sqlite pragma #{name} to #{value}" }
        end
      end

      # reset the store; delete all data
      def reset
        raise "Not implemented"
      end


      def new_block blk
        time = Time.now
        res = store_block(blk)
        log.info { "block #{blk.hash} " +
          "[#{res[0]}, #{['main', 'side', 'orphan'][res[1]]}] " +
          "(#{"%.4fs, %3dtx, %.3fkb" % [(Time.now - time), blk.tx.size, blk.payload.bytesize.to_f/1000]})" }  if res && res[1]
        res
      end

      # store given block +blk+.
      # determine branch/chain and dept of block. trigger reorg if side branch becomes longer
      # than current main chain and connect orpans.
      def store_block blk
        log.debug { "new block #{blk.hash}" }

        existing = get_block(blk.hash)
        if existing && existing.chain == MAIN
          log.debug { "=> exists (#{existing.depth}, #{existing.chain})" }
          return [existing.depth]
        end

        prev_block = get_block(blk.prev_block.reverse_hth)
        unless @config[:skip_validation]
          validator = blk.validator(self, prev_block)
          validator.validate(rules: [:syntax], raise_errors: true)
        end

        if !prev_block || prev_block.chain == ORPHAN
          if blk.hash == Bitcoin.network[:genesis_hash]
            log.debug { "=> genesis (0)" }
            return persist_block(blk, MAIN, 0)
          else
            depth = prev_block ? prev_block.depth + 1 : 0
            log.debug { "=> orphan (#{depth})" }
            return [0, 2]  unless in_sync?
            return persist_block(blk, ORPHAN, depth)
          end
        end
        depth = prev_block.depth + 1

        checkpoint = @checkpoints[depth]
        if checkpoint && blk.hash != checkpoint
          log.warn "Block #{depth} doesn't match checkpoint #{checkpoint}"
          exit  if depth > get_depth # TODO: handle checkpoint mismatch properly
        end
        if prev_block.chain == MAIN
          if prev_block == get_head
            log.debug { "=> main (#{depth})" }
            if !@config[:skip_validation] && ( !@checkpoints.any? || depth > @checkpoints.keys.last )
              @config[:utxo_cache] = 0  if self.class.name =~ /UtxoStore/
              validator.validate(rules: [:context], raise_errors: true)
            end
            return persist_block(blk, MAIN, depth, prev_block.work)
          else
            log.debug { "=> side (#{depth})" }
            return persist_block(blk, SIDE, depth, prev_block.work)
          end
        else
          head = get_head
          if prev_block.work + blk.block_work  <= head.work
            log.debug { "=> side (#{depth})" }
            validator.validate(rules: [:context], raise_errors: true)  unless @config[:skip_validation]
            return persist_block(blk, SIDE, depth, prev_block.work)
          else
            log.debug { "=> reorg" }
            new_main, new_side = [], []
            fork_block = prev_block
            while fork_block.chain != MAIN
              new_main << fork_block.hash
              fork_block = fork_block.get_prev_block
            end
            b = fork_block
            while b = b.get_next_block
              new_side << b.hash
            end
            log.debug { "new main: #{new_main.inspect}" }
            log.debug { "new side: #{new_side.inspect}" }
            reorg(new_side.reverse, new_main.reverse)
            return persist_block(blk, MAIN, depth, prev_block.work)
          end
        end
      end

      # persist given block +blk+ to storage.
      def persist_block(blk)
        raise "Not implemented"
      end

      # update +attrs+ for block with given +hash+.
      # typically used to update the chain value during reorg.
      def update_block(hash, attrs)
        raise "Not implemented"
      end

      def new_tx(tx)
        store_tx(tx)
      end

      # store given +tx+
      def store_tx(tx, validate = true)
        raise "Not implemented"
      end

      # check if block with given +blk_hash+ is already stored
      def has_block(blk_hash)
        raise "Not implemented"
      end

      # check if tx with given +tx_hash+ is already stored
      def has_tx(tx_hash)
        raise "Not implemented"
      end

      # get the hash of the leading block
      def get_head
        raise "Not implemented"
      end

      # return depth of the head block
      def get_depth
        raise "Not implemented"
      end

      # compute blockchain locator
      def get_locator pointer = get_head
        if @locator
          locator, head = @locator
          if head == get_head
            return locator
          end
        end

        return [("\x00"*32).hth]  if get_depth == -1
        locator = []
        step = 1
        while pointer && pointer.hash != Bitcoin::network[:genesis_hash]
          locator << pointer.hash
          depth = pointer.depth - step
          break unless depth > 0
          prev_block = get_block_by_depth(depth) # TODO
          break unless prev_block
          pointer = prev_block
          step *= 2  if locator.size > 10
        end
        locator << Bitcoin::network[:genesis_hash]
        @locator = [locator, get_head]
        locator
      end

      # get block with given +blk_hash+
      def get_block(blk_hash)
        raise "Not implemented"
      end

      # get block with given +depth+ from main chain
      def get_block_by_depth(depth)
        raise "Not implemented"
      end

      # get block with given +prev_hash+
      def get_block_by_prev_hash(prev_hash)
        raise "Not implemented"
      end

      # get block that includes tx with given +tx_hash+
      def get_block_by_tx(tx_hash)
        raise "Not implemented"
      end

      # get block by given +block_id+
      def get_block_by_id(block_id)
        raise "Not implemented"
      end

      # get corresponding txin for the txout in
      # transaction +tx_hash+ with index +txout_idx+
      def get_txin_for_txout(tx_hash, txout_idx)
        raise "Not implemented"
      end

      # get tx with given +tx_hash+
      def get_tx(tx_hash)
        raise "Not implemented"
      end

      # get tx with given +tx_id+
      def get_tx_by_id(tx_id)
        raise "Not implemented"
      end

      # collect all txouts containing the
      # given +script+
      def get_txouts_for_pk_script(script)
        raise "Not implemented"
      end

      # collect all txouts containing a
      # standard tx to given +address+
      def get_txouts_for_address(address, unconfirmed = false)
        hash160 = Bitcoin.hash160_from_address(address)
        get_txouts_for_hash160(hash160, unconfirmed)
      end

      # get balance for given +hash160+
      def get_balance(hash160, unconfirmed = false)
        txouts = get_txouts_for_hash160(hash160, unconfirmed)
        unspent = txouts.select {|o| o.get_next_in.nil?}
        unspent.map(&:value).inject {|a,b| a+=b; a} || 0
      rescue
        nil
      end


      # store address +hash160+
      def store_addr(txout_id, hash160)
        addr = @db[:addr][:hash160 => hash160]
        addr_id = addr[:id]  if addr
        addr_id ||= @db[:addr].insert({:hash160 => hash160})
        @db[:addr_txout].insert({:addr_id => addr_id, :txout_id => txout_id})
      end

      # parse script and collect address/txout mappings to index
      def parse_script txout, i
        addrs, names = [], []
        # skip huge script in testnet3 block 54507 (998000 bytes)
        return [SCRIPT_TYPES.index(:unknown), [], []]  if txout.pk_script.bytesize > 10_000
        script = Bitcoin::Script.new(txout.pk_script) rescue nil
        if script
          if script.is_hash160? || script.is_pubkey?
            addrs << [i, script.get_hash160]
          elsif script.is_multisig?
            script.get_multisig_pubkeys.map do |pubkey|
              addrs << [i, Bitcoin.hash160(pubkey.unpack("H*")[0])]
            end
          elsif Bitcoin.namecoin? && script.is_namecoin?
            addrs << [i, script.get_hash160]
            names << [i, script]
          else
            log.warn { "Unknown script type"}# #{tx.hash}:#{txout_idx}" }
          end
          script_type = SCRIPT_TYPES.index(script.type)
        else
          log.error { "Error parsing script"}# #{tx.hash}:#{txout_idx}" }
          script_type = SCRIPT_TYPES.index(:unknown)
        end
        [script_type, addrs, names]
      end

      # import satoshi bitcoind blk0001.dat blockchain file
      def import filename, max_depth = nil
        if File.file?(filename)
          log.info { "Importing #{filename}" }
          File.open(filename) do |file|
            until file.eof?
              magic = file.read(4)
              raise "invalid network magic"  unless Bitcoin.network[:magic_head] == magic
              size = file.read(4).unpack("L")[0]
              blk = Bitcoin::P::Block.new(file.read(size))
              depth, chain = new_block(blk)
              break  if max_depth && depth >= max_depth
            end
          end
        elsif File.directory?(filename)
          Dir.entries(filename).sort.each do |file|
            next  unless file =~ /^blk.*?\.dat$/
            import(File.join(filename, file), max_depth)
          end
        else
          raise "Import dir/file #{filename} not found"
        end
      end

      def in_sync?
        (get_head && (Time.now - get_head.time).to_i < 3600) ? true : false
      end
    end
  end
end

# TODO: someday sequel will support #blob directly and #to_sequel_blob will be gone
class String; def blob; to_sequel_blob; end; end
