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

  # Block retrieved from storage. (see Bitcoin::Protocol::Block)
  class Block < Bitcoin::Protocol::MerkleBlock

    attr_accessor :ver, :prev_block_hash, :mrkl_root, :time, :bits, :nonce, :tx
    attr_reader :store, :id, :height, :chain, :work, :size

    def initialize store, data
      @store = store
      @id = data[:id]
      @height = data[:height]
      @chain = data[:chain]
      @work = data[:work]
      @size = data[:size]
      @tx = []
    end

    # Get the previous block this one builds upon.
    def prev_block
      @store.block(@prev_block_hash.reverse_hth)
    end
    alias :get_prev_block :prev_block

    # Get the hash of the previous block.
    def prev_block_hash
      @prev_block_hash
    end

    # Get the next block that builds upon this one.
    def next_block
      @store.block_by_prev_hash(@hash)
    end
    alias :get_next_block :next_block

    # Get the total value of outputs of all transaction in this block.
    # Note:: only works with +sequel+ backend
    def total_out
      @total_out ||= tx.inject(0){ |m,t| m + t.total_out } rescue nil
    end

    # Get the total value of inputs to al transactions in this block.
    # Note:: only works with +sequel+ backend
    def total_in
      @total_in ||= tx.inject(0){ |m,t| m + t.total_in } rescue nil
    end

    # Get the total fee of all transactions in this block.
    # Note:: only works with +sequel+ backend
    def total_fee
      @total_fee ||= tx.inject(0){ |m,t| m + t.fee } rescue nil
    end

    # backward-compatibility
    def depth; @height; end

  end

  # Transaction retrieved from storage. (see Bitcoin::Protocol::Tx)
  class Tx < Bitcoin::Protocol::Tx

    attr_accessor :ver, :lock_time, :hash
    attr_reader :store, :id, :blk_id, :size, :idx

    def initialize store, data
      @store = store
      @id = data[:id]
      @blk_id = data[:blk_id]
      @size = data[:size]
      @idx  = data[:idx]
      super(nil)
    end

    # Get the block this transaction is in.
    def block
      return nil  unless @blk_id
      @block ||= @store.block_by_id(@blk_id)
    end
    alias :get_block :block

    # Get the number of blocks that confirm this tx in the main chain.
    def confirmations
      return 0  unless block
      @store.head.height - block.height + 1
    end

    # Get the total value of all outputs of this transaction.
    # Note:: doesn't work with +utxo+ backend
    def total_out
      @total_out ||= self.out.inject(0){ |e, o| e + o.value }
    end

    # Get the total value of all inputs to this transaction.
    # If tx_in is coinbase, set in value as total_out, fee could be 0.
    # Note:: doesn't work with +utxo+ backend
    def total_in
      @total_in ||= self.in.inject(0){ |m, input|
        m + (input.coinbase? ? total_out : (input.prev_out.try(:value) || 0))
      }
    end

    # Get the fee (input value - output value) of this transaction.
    # Note:: doesn't work with +utxo+ backend
    def fee
      @fee ||= total_in - total_out
    end
  end

  # Transaction input retrieved from storage. (see Bitcoin::Protocol::TxIn
  class TxIn < Bitcoin::Protocol::TxIn

    attr_reader :store, :id, :tx_id, :tx_idx, :p2sh_type

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

    attr_reader :store, :id, :tx_id, :tx_idx, :type

    def initialize store, data
      @store = store
      @id = data[:id]
      @tx_id = data[:tx_id]
      @tx_idx = data[:tx_idx]
      @type = data[:type]
    end

    def hash160
      parsed_script.get_hash160
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

    def type
      parsed_script.type
    end

  end

end
