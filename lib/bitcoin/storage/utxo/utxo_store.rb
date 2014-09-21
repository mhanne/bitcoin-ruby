Bitcoin.require_dependency :sequel, message:
  "Note: You will also need an adapter for your database like sqlite3, mysql2, postgresql"

module Bitcoin::Storage::Backends

  # Storage backend using Sequel to connect to arbitrary SQL databases.
  # Inherits from StoreBase and implements its interface.
  class UtxoStore < SequelStoreBase

    # possible script types
    SCRIPT_TYPES = [:unknown, :pubkey, :hash160, :multisig, :p2sh]
    if Bitcoin.namecoin?
      [:name_new, :name_firstupdate, :name_update].each {|n| SCRIPT_TYPES << n }
    end

    # sequel database connection
    attr_accessor :db

    DEFAULT_CONFIG = {
      # cache head block; it is only updated when new block comes in,
      # so this should only be used by the store receiving new blocks.
      cache_head: false,
      # cache this many utxo records before syncing to disk.
      # this should only be enabled during initial sync, because
      # with it the store cannot reorg properly.
      utxo_cache: 250,
      # cache this many blocks.
      # NOTE: this is also the maximum number of blocks the store can reorg.
      block_cache: 120,
      # keep an index of utxos for all addresses, not just the ones
      # we are explicitly told about.
      index_all_addrs: false
    }

    # create sequel store with given +config+
    def initialize config, *args
      super config, *args
      @spent_outs, @new_outs, @watched_addrs = [], [], []
      @tx_cache, @block_cache = {}, {}
    end

    # connect to database
    def connect
      super
      load_watched_addrs
#      rescan

    end

    # reset database; delete all data
    def reset
      super
      @spent_outs, @new_outs, @watched_addrs = [], [], []
      @deleted_utxos, @tx_cache, @block_cache = {}, {}, {}
    end

    # persist given block +blk+ to storage.
    def persist_block blk, chain, height, prev_work = 0
      load_watched_addrs
      db.transaction do
        attrs = {
          hash: blk.hash.htb.blob,
          height: height,
          chain: chain,
          version: blk.ver,
          prev_hash: blk.prev_block.reverse.blob,
          mrkl_root: blk.mrkl_root.reverse.blob,
          time: blk.time,
          bits: blk.bits,
          nonce: blk.nonce,
          blk_size: blk.payload.bytesize,
          work: (prev_work + blk.block_work).to_s
        }
        existing = db.blocks.filter(hash: blk.hash.htb.blob)
        if existing.any?
          existing.update attrs
          block_id = existing.first[:id]
        else
          block_id = db.blocks.insert(attrs)
        end

        if @config[:block_cache] > 0
          @block_cache.shift  if @block_cache.size > @config[:block_cache]
          @block_cache[blk.hash] = blk
        end

        if chain == MAIN
          persist_transactions(blk.tx, block_id, height)
          @tx_cache = {}
          @head = wrap_block(attrs.merge(id: block_id))  if chain == MAIN
        end
        return height, chain
      end
    end

    def store_tx *args
      # TODO
    end

    def persist_transactions txs, block_id, height
      txs.each.with_index do |tx, tx_blk_idx|
        tx.in.each.with_index do |txin, txin_tx_idx|
          next  if txin.coinbase?
          size = @new_outs.size
          @new_outs.delete_if {|o| o[0][:tx_hash] == txin.prev_out.reverse.hth &&
            o[0][:tx_idx] == txin.prev_out_index }
          @spent_outs << {
            tx_hash: txin.prev_out.reverse.hth.to_sequel_blob,
            tx_idx: txin.prev_out_index  }  if @new_outs.size == size
        end
        tx.out.each.with_index do |txout, txout_tx_idx|
          _, a, n = *parse_script(txout, txout_tx_idx, tx.hash, txout_tx_idx)
          @new_outs << [{
              tx_hash: tx.hash.blob,
              tx_idx: txout_tx_idx,
              blk_id: block_id,
              pk_script: txout.pk_script.blob,
              value: txout.value },
            @config[:index_all_addrs] ? a : a.select {|a| @watched_addrs.include?(a[1]) },
            Bitcoin.namecoin? ? n : [] ]
        end
        flush_spent_outs(height)  if @spent_outs.size > @config[:utxo_cache]
        flush_new_outs(height)  if @new_outs.size > @config[:utxo_cache]
      end
    end

    def reorg new_side, new_main
      new_side.each do |block_hash|
        raise "trying to remove non-head block!"  unless head.hash == block_hash
        blk = db.blocks[hash: block_hash.htb.blob]
        delete_utxos = db.outputs.where(blk_id: blk[:id])
        db.address_outputs.where("txout_id IN ?", delete_utxos.map{|o|o[:id]}).delete
        db.blocks.where(id: blk[:id]).update(chain: SIDE)
        delete_utxos.delete
      end

      new_main.each do |block_hash|
        block = db.blocks[hash: block_hash.htb.blob]
        blk = @block_cache[block_hash]
        persist_transactions(blk.tx, block[:id], block[:height])
        db.blocks.where(id: block[:id]).update(chain: MAIN)
      end
    end

    def flush_spent_outs height
      log.time "flushed #{@spent_outs.size} spent txouts in %.4fs" do
        if @spent_outs.any?
          @spent_outs.each_slice(250) do |slice|
            if db.adapter_scheme == :postgres
              condition = slice.map {|o| "(tx_hash = '#{o[:tx_hash]}' AND tx_idx = #{o[:tx_idx]})" }.join(" OR ")
            else
              condition = slice.map {|o| "(tx_hash = X'#{o[:tx_hash].hth}' AND tx_idx = #{o[:tx_idx]})" }.join(" OR ")
            end
            db["DELETE FROM #{TABLES[:address_outputs]} WHERE EXISTS
                   (SELECT 1 FROM #{TABLES[:outputs]} WHERE
                     #{TABLES[:outputs]}.id = #{TABLES[:address_outputs]}.txout_id AND (#{condition}));"].all
            db["DELETE FROM #{TABLES[:outputs]} WHERE #{condition};"].first

          end
        end
        @spent_outs = []
      end
    end

    def flush_new_outs height
      log.time "flushed #{@new_outs.size} new txouts in %.4fs" do
        new_utxo_ids = db.outputs.insert_multiple(@new_outs.map{|o|o[0]})
        @new_outs.each.with_index do |d, idx|
          d[1].each do |i, hash160|
            next  unless i && hash160
            store_addr(new_utxo_ids[idx], hash160)
          end
        end

        @new_outs.each.with_index do |d, idx|
          d[2].each do |i, script|
            next  unless i && script
            store_name(script, new_utxo_ids[idx])
          end
        end
        @new_outs = []
      end
    end

    # store hash160 and type of +addr+
    def store_addr(txout_id, addr)
      hash160 = Bitcoin.hash160_from_address(addr)
      type = ADDRESS_TYPES.index(Bitcoin.address_type(addr))

      addr = db.addresses[hash160: hash160, type: type]
      addr_id = addr[:id]  if addr
      addr_id ||= db.addresses.insert(hash160: hash160, type: type)

      db.address_outputs.insert(addr_id: addr_id, txout_id: txout_id)
    end

    def add_watched_address address, height = height
      hash160 = Bitcoin.hash160_from_address(address)
      db.addresses.insert(hash160: hash160)  unless db.addresses[hash160: hash160]
      @watched_addrs << hash160  unless @watched_addrs.include?(hash160)
    end

    def load_watched_addrs
      @watched_addrs = db.addresses.all.map{|a| a[:hash160] }  unless @config[:index_all_addrs]
    end

    def rescan
      load_watched_addrs
      @rescan_lock ||= Monitor.new
      @rescan_lock.synchronize do
        log.info { "Rescanning #{db.outputs.count} utxos for #{@watched_addrs.size} addrs" }
        count = db.outputs.count; n = 100_000
        db.outputs.order(:id).each_slice(n).with_index do |slice, index|
          log.debug { "rescan progress: %.2f%" % (100.0 / count * (index*n)) }
          slice.each do |utxo|
            next  if utxo[:pk_script].bytesize >= 10_000
            hash160 = Bitcoin::Script.new(utxo[:pk_script]).hash160
            if @config[:index_all_addrs] || @watched_addrs.include?(hash160)
              log.info { "Found utxo for address #{Bitcoin.hash160_to_address(hash160)}: " +
                "#{utxo[:tx_hash][0..8]}:#{utxo[:tx_idx]} (#{utxo[:value]})" }
              addr = db.addresses[hash160: hash160]
              addr_utxo = {addr_id: addr[:id], txout_id: utxo[:id]}
              db.address_outputs.insert(addr_utxo)  unless db.address_outputs[addr_utxo]
            end
          end
        end
      end
    end

    # check if block +blk_hash+ exists
    def has_block(blk_hash)
      !!db.blocks.where(hash: blk_hash.htb.blob).get(1)
    end

    # check if transaction +tx_hash+ exists
    def has_tx(tx_hash)
      !!db.outputs.where(tx_hash: tx_hash.blob).get(1)
    end

    # get head block (highest block from the MAIN chain)
    def head
      (@config[:cache_head] && @head) ? @head :
        @head = wrap_block(db.blocks.filter(chain: MAIN).order(:height).last)
    end
    alias :get_head :head

    # get height of MAIN chain
    def height
      return -1  unless head
      head.height
    end
    alias :get_depth :height

    # get block for given +blk_hash+
    def block(blk_hash)
      wrap_block(db.blocks[hash: blk_hash.htb.blob])
    end
    alias :get_block :block

    # get block by given +height+
    def block_at_height(height)
      wrap_block(db.blocks[height: height, chain: MAIN])
    end
    alias :get_block_by_depth :block_at_height

    # get block by given +prev_hash+
    def block_by_prev_hash(prev_hash)
      wrap_block(db.blocks[prev_hash: prev_hash.htb.blob, chain: MAIN])
    end
    alias :get_block_by_prev_hash :block_by_prev_hash

    # get block by given +tx_hash+
    def block_by_tx(tx_hash)
      block_id = db.outputs[tx_hash: tx_hash.blob][:blk_id]
      block_by_id(block_id)
    end
    alias :get_block_by_tx :block_by_tx

    # get block by given +id+
    def block_by_id(block_id)
      wrap_block(db.blocks[id: block_id])
    end
    alias :get_block_by_id :block_by_id

    # get transaction for given +tx_hash+
    def tx(tx_hash)
      @tx_cache[tx_hash] ||= wrap_tx(tx_hash)
    end
    alias :get_tx :tx

    # get transaction by given +tx_id+
    def tx_by_id(tx_id)
      tx(tx_id)
    end
    alias :get_tx_by_id :tx_by_id

    def txout_by_id(id)
      wrap_txout(db.outputs[id: id])
    end
    alias :get_txout_by_id :txout_by_id

    # get corresponding Models::TxOut for +txin+
    def txout_for_txin(txin)
      wrap_txout(db.outputs[tx_hash: txin.prev_out.reverse.hth.blob, tx_idx: txin.prev_out_index])
    end
    alias :get_txout_for_txin :txout_for_txin

    # get the next input that references given output
    # we only store unspent outputs, so it's always nil
    def txin_for_txout(tx_hash, tx_idx)
      nil
    end
    alias :get_txin_for_txout :txin_for_txout

    # get all Models::TxOut matching given +script+
    def txouts_for_pk_script(script)
      utxos = db.outputs.filter(pk_script: script.blob).order(:blk_id)
      utxos.map {|utxo| wrap_txout(utxo) }
    end
    alias :get_txouts_for_pk_script :txouts_for_pk_script

    # get all Models::TxOut matching given +hash160+
    def txouts_for_hash160(hash160, type = :hash160, unconfirmed = false)
      addr = db.addresses[hash160: hash160, type: ADDRESS_TYPES.index(type)]
      return []  unless addr
      db.address_outputs.where(addr_id: addr[:id]).map {|ao| wrap_txout(db.outputs[id: ao[:txout_id]]) }.compact
    end
    alias :get_txouts_for_hash160 :txouts_for_hash160

    # wrap given +block+ into Models::Block
    def wrap_block(block)
      return nil  unless block

      data = { id: block[:id], height: block[:height], chain: block[:chain],
        work: block[:work].to_i, hash: block[:hash].hth }
      blk = Bitcoin::Storage::Models::Block.new(self, data)

      blk.ver = block[:version]
      blk.prev_block = block[:prev_hash].reverse
      blk.mrkl_root = block[:mrkl_root].reverse
      blk.time = block[:time].to_i
      blk.bits = block[:bits]
      blk.nonce = block[:nonce]

      if cached = @block_cache[block[:hash].hth]
        blk.tx = cached.tx
      end

      blk.recalc_block_hash
      blk
    end

    # wrap given +transaction+ into Models::Transaction
    def wrap_tx(tx_hash)
      utxos = db.outputs.where(tx_hash: tx_hash.blob)
      return nil  unless utxos.any?
      data = { blk_id: utxos.first[:blk_id], id: tx_hash }
      tx = Bitcoin::Storage::Models::Tx.new(self, data)
      tx.hash = tx_hash # utxos.first[:tx_hash].hth
      utxos.each {|u| tx.out[u[:tx_idx]] = wrap_txout(u) }
      return tx
    end

    # wrap given +output+ into Models::TxOut
    def wrap_txout(utxo)
      return nil  unless utxo
      data = {id: utxo[:id], tx_id: utxo[:tx_hash], tx_idx: utxo[:tx_idx]}
      txout = Bitcoin::Storage::Models::TxOut.new(self, data)
      txout.value = utxo[:value]
      txout.pk_script = utxo[:pk_script]
      txout
    end

    def check_consistency(*args)
      log.warn { "Utxo store doesn't support consistency check" }
    end

    def storage_mode
      :utxo
    end

  end

end
