# encoding: ascii-8bit

# StorageModels defines objects that are returned from storage.
# These objects inherit from their Bitcoin::Protocol counterpart
# and add some additional data and methods.
#
# * Bitcoin::Storage::Models::Block
# * Bitcoin::Storage::Models::Tx
# * Bitcoin::Storage::Models::TxIn
# * Bitcoin::Storage::Models::TxOut
module Bitcoin::Storage::Models

  # Block retrieved from storage. This extends Bitcoin::Protocol::Block, adds
  # variables to keep track of the block's context in the blockchain (height, chain, work),
  # and provides some helpers to query for related data.
  class Block < Bitcoin::Protocol::MerkleBlock

    # Bitcoin::Storage backend used to query for more data
    attr_accessor :store

    # Database-internal ID of this block record
    attr_accessor :id

    # The height that this block is at inside the chain
    attr_accessor :height

    # Hash of this block's header
    attr_accessor :hash

    # Which (branch of the) chain this block is on (:main, :side, :orphan)
    attr_accessor :chain

    # Total work expended to mine the whole chain up to this block
    attr_accessor :work

    # Merkle root of all transaction hashes included in this block
    attr_accessor :mrkl_root

    # Timestamp of this block (not very accurate, see timestamp validation rules)
    attr_accessor :time

    # Compact Bits representing the target difficulty this block's hash satisfies
    attr_accessor :bits

    # Nonce used to make the hash satisfy the difficulty
    attr_accessor :nonce

    # AuxPow linking the block to a merge-mined chain
    attr_accessor :aux_pow

    # Block protocol version
    attr_accessor :ver

    # Size of the raw block in bytes
    attr_accessor :size

    def initialize store, data
      @store = store
      @id = data[:id]
      @height = data[:height]
      @chain = data[:chain]
      @work = data[:work]
      @size = data[:size]
      @tx = []
    end

    # get the block this one builds upon
    def prev_block
      @store.block(@prev_block_hash.reverse_hth)
    end
    alias :get_prev_block :prev_block

    def prev_block_hash
      @prev_block_hash
    end

    # get the block that builds upon this one
    def next_block
      @store.block_by_prev_hash(@hash)
    end
    alias :get_next_block :next_block

    def total_out
      @total_out ||= tx.inject(0){ |m,t| m + t.total_out }
    end

    def total_in
      @total_in ||= tx.inject(0){ |m,t| m + t.total_in }
    end

    def total_fee
      @total_fee ||= tx.inject(0){ |m,t| m + t.fee }
    end

    # backward-compatibility
    def depth; @height; end

  end

  # Transaction retrieved from storage. (see Bitcoin::Protocol::Tx)
  class Tx < Bitcoin::Protocol::Tx

    # Bitcoin::Storage backend used to query for more data
    attr_accessor :store

    # Database-internal ID of this tx record
    attr_accessor :id

    # Database-internal ID of the block this tx belongs to
    attr_accessor :blk_id

    # Index of this transaction in the block it belongs to
    attr_accessor :idx

    # Hash of this transaction
    attr_accessor :hash

    # Transaction protocol version
    attr_accessor :ver

    # Size of the raw transaction in bytes
    attr_accessor :size

    def initialize store, data
      @store = store
      @id = data[:id]
      @blk_id = data[:blk_id]
      @size = data[:size]
      @idx  = data[:idx]
      super(nil)
    end

    # get the block this transaction is in
    def block
      return nil  unless @blk_id
      @block ||= @store.block_by_id(@blk_id)
    end
    alias :get_block :block

    # get the number of blocks that confirm this tx in the main chain
    def confirmations
      return 0  unless block
      @store.head.height - block.height + 1
    end

    def total_out
      @total_out ||= self.out.inject(0){ |e, o| e + o.value }
    end

    # if tx_in is coinbase, set in value as total_out, fee could be 0
    def total_in
      @total_in ||= self.in.inject(0){ |m, input|
        m + (input.coinbase? ? total_out : (input.prev_out.try(:value) || 0))
      }
    end

    def fee
      @fee ||= total_in - total_out
    end

  end

  # Transaction input retrieved from storage. (see Bitcoin::Protocol::TxIn
  class TxIn < Bitcoin::Protocol::TxIn

    # Bitcoin::Storage backend used to query for more data
    attr_accessor :store

    # Database-internal ID of this txin record
    attr_accessor :id

    # Database-internal ID of the tx record this txin belongs to
    attr_accessor :tx_id

    # Index of this txin in the tx it belongs to
    attr_accessor :tx_idx

    # Index of the output in the +prev_out_hash+ tx that is being consumed
    attr_accessor :prev_out_index

    # Signature script proving ownership of the coins being transfered
    attr_accessor :script_sig

    # If this input spends a p2sh output, this holds the type of the inner p2sh script
    # (one of Bitcoin::Storage::Backends::StoreBase::SCRIPT_TYPES)
    attr_accessor :p2sh_type

    def initialize store, data
      @store = store
      @id = data[:id]
      @tx_id = data[:tx_id]
      @tx_idx = data[:tx_idx]
      @p2sh_type = data[:p2sh_type]
    end

    # get the transaction this input is in
    def tx
      @tx ||= @store.tx_by_id(@tx_id)
    end
    alias :get_tx :tx

    # get the previous output referenced by this input
    def prev_out
      @prev_tx_out ||= begin
        prev_tx = @store.tx(@prev_out.reverse_hth)
        return nil  unless prev_tx
        prev_tx.out[@prev_out_index]
      end
    end
    alias :get_prev_out :prev_out

  end

  # Transaction output retrieved from storage. (see Bitcoin::Protocol::TxOut)
  class TxOut < Bitcoin::Protocol::TxOut

    # Bitcoin::Storage backend used to query for more data
    attr_accessor :store

    # Database-internal ID of this txin record
    attr_accessor :id

    # Database-internal ID of the tx record this txout belongs to
    attr_accessor :tx_id

    # Index of this txout in the tx it belongs to
    attr_accessor :tx_idx

    # Value spent by this output (in base units / satoshis)
    attr_accessor :value

    # Type of the output script
    attr_accessor :type

    def initialize store, data
      @store = store
      @id = data[:id]
      @tx_id = data[:tx_id]
      @tx_idx = data[:tx_idx]
      @type = data[:type]
    end

    # get the transaction this output is in
    def tx
      @tx ||= @store.tx_by_id(@tx_id)
    end
    alias :get_tx :tx

    # get the next input that references this output
    def next_in
      @store.txin_for_txout(tx.hash, @tx_idx)
    end
    alias :get_next_in :next_in

    # get the single address this txout corresponds to (first for multisig tx)
    def address
      parsed_script.get_address
    end
    alias :get_address :address

    # get all addresses this txout corresponds to (if possible)
    def addresses
      parsed_script.get_addresses
    end
    alias :get_addresses :addresses

    def namecoin_name
      @store.name_by_txout_id(@id)
    end
    alias :get_namecoin_name :namecoin_name

    # get the hash160 used by the output script (if any)
    # Note: this only makes sense in combination with the #type!
    def hash160
      parsed_script.get_hash160
    end

    # get the type of the output script
    def type
      parsed_script.type
    end

  end

end
