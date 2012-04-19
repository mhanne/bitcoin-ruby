module Bitcoin

  class ValidationError < StandardError
  end

  class TxValidator

    MAX_BLOCK_SIZE = 1_000_000
    MAX_MONEY = 21_000_000 * 1e8
    MAX_INT = 4294967295

    def initialize store, tx
      @store = store
      @tx = tx
    end

    def validate
      # tx.verify_input_signature(0, outpoint_tx).should == true

      # puts "Validating tx #{@tx.hash}"

      [
        :syntax,
        :in_out_size,
        :size,
        :money_range,
        :no_coinbase_inputs,
        :lock_time,
        :min_size,
        :opcount,
        :is_standard,
        :no_duplicate,
        :no_used_outputs,
        :outputs_present,
        :output_index,
        :coinbase_maturity,
        :signatures,
        :no_doublespend,
        :sum_money_range,
        :total_output_value,
        :fee,
      ].each do |rule|
        res = send("validate_#{rule}")
        raise ValidationError.new(rule)  unless res
      end

      # puts "Tx #{@tx.hash} is valid!"

      # :store
      # :add_to_wallet
      # :relay
      # :revalidate_orphans
      true
    end


    # Check syntactic correctness
    def validate_syntax
      true # implicitly done by parser
    end

    # Make sure neither in or out lists are empty
    def validate_in_out_size
      @tx.in.any? && @tx.out.any?
    end

    # Size in bytes < MAX_BLOCK_SIZE
    def validate_size
      @tx.payload.bytesize < MAX_BLOCK_SIZE
    end


    # Each output value, as well as the total, must be in legal money range
    def validate_money_range
      @tx.out.map(&:value).inject{|a,b| a+=b;a} < MAX_MONEY
    end

    # Make sure none of the inputs have hash=0, n=-1 (coinbase transactions)
    def validate_no_coinbase_inputs
      !@tx.in.map{|i| i.prev_out == "\x00"*32 && i.prev_out_index == 4294967295 }.any?
      true # TODO
    end

    # Check that nLockTime <= INT_MAX[1],
    def validate_lock_time
      @tx.lock_time <= MAX_INT
    end

    # size in bytes >= 100[2],
    def validate_min_size
      @tx.payload.bytesize >= 100
    end

    # and sig opcount <= 2[3]
    def validate_opcount
      @tx.out.map{|o| Script.new(o.pk_script).sig_op_count}.inject{|a,b| a+=b;a} <= 2
      true # TODO
    end

    # Reject "nonstandard" transactions: scriptSig doing anything other than pushing numbers on the stack, or scriptPubkey not matching the two usual forms[4]
    def validate_is_standard
      true # TODO
    end

    # Reject if we already have matching tx in the pool, or in a block in the main branch
    def validate_no_duplicate
      !@store.has_tx(@tx.hash)
    end

    # Reject if any other tx in the pool uses the same transaction output as one used by this tx.[5]
    def validate_no_used_outputs # TODO: sequence handling
      true # TODO
    end

    # For each input, look in the main branch and the transaction pool to find the referenced output transaction. If the output transaction is missing for any input, this will be an orphan transaction. Add to the orphan transactions, if a matching transaction is not in there already.
    def validate_outputs_present
      true # TODO
    end

    # For each input, if we are using the nth output of the earlier transaction, but it has fewer than n+1 outputs, reject this transaction
    def validate_output_index
      true # TODO
    end

    # For each input, if the referenced output transaction is coinbase (i.e. only 1 input, with hash=0, n=-1), it must have at least COINBASE_MATURITY confirmations; else reject this transaction
    def validate_coinbase_maturity
      true # TODO
    end

    # Verify crypto signatures for each input; reject if any are bad
    def validate_signatures
      @tx.in.each_with_index do |txin, idx|
        prev_tx = @store.get_tx(Bitcoin::hth(txin.prev_out.reverse))
        next unless prev_tx # TODO

        result = @tx.verify_input_signature(idx, prev_tx)

        #        txout = prev_tx.out[txin.prev_out_index]
        #        script = Script.new(txin.script_sig + txout.pk_script)

        #        debug = []
        #        result = script.run(debug) do |pubkey, sig, hash_type|
        #          hash = @tx.signature_hash_for_input(idx, nil, txout.pk_script)
        #          Bitcoin.verify_signature(hash, sig, pubkey.unpack("H*")[0])
        #        end

        #        binding.pry  if result != true

        return false unless result
      end
      return true
    end

    # For each input, if the referenced output has already been spent by a transaction in the main branch, reject this transaction[6]
    def validate_no_doublespend
      true # TODO
    end

    # Using the referenced output transactions to get input values, check that each input value, as well as the sum, are in legal money range
    def validate_sum_money_range
      true # TODO
    end

    # Reject if the sum of input values < sum of output values
    def validate_total_output_value
      true # TODO
    end

    # Reject if transaction fee (defined as sum of input values minus sum of output values) would be too low to get into an empty block
    def validate_fee
      true # TODO
    end

    # Add to transaction pool[7]
    def store

    end

    # "Add to wallet if mine"
    def add_to_wallet

    end

    # Relay transaction to peers
    def relay

    end

    # For each orphan transaction that uses this one as one of its inputs, run all these steps (including this one) recursively on that orphan 
    def revalidate_orphans

    end

  end

end
