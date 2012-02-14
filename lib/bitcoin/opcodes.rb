module Bitcoin::Opcodes
  OP_1           = 81
  OP_TRUE        = 81
  OP_0           = 0
  OP_FALSE       = 0
  OP_PUSHDATA1   = 76
  OP_PUSHDATA2   = 77
  OP_PUSHDATA4   = 78
  OP_NOP         = 97
  OP_DUP         = 118
  OP_HASH160     = 169
  OP_EQUAL       = 135
  OP_VERIFY      = 105
  OP_EQUALVERIFY = 136
  OP_CHECKSIG    = 172
  OP_CHECKSIGVERIFY      = 173
  OP_CHECKMULTISIG       = 174
  OP_CHECKMULTISIGVERIFY = 175
  OP_TOALTSTACK   = 107
  OP_FROMALTSTACK = 108
  OP_TUCK         = 125
  OP_SWAP         = 124
  OP_BOOLAND      = 154
  OP_ADD          = 147
  OP_SUB          = 148
  OP_GREATERTHANOREQUAL = 162
  OP_DROP         = 117
  OP_HASH256      = 170
  OP_SHA256       = 168
  OP_SHA1         = 167
  OP_RIPEMD160    = 166
  OP_EVAL         = 176
  OP_NOP2         = 177
  OP_CHECKHASHVERIFY = 177
  OP_CODESEPARATOR = 171

  OPCODES = Hash[*constants.grep(/^OP_/).map{|i| [const_get(i), i.to_s] }.flatten]
  OPCODES[0] = "0"
  OPCODES[81] = "1"

  OPCODES_ALIAS = {
    "OP_TRUE"  => OP_1,
    "OP_FALSE" => OP_0,
    "OP_NOP1" => OP_EVAL,
    "OP_NOP2" => OP_CHECKHASHVERIFY
  }

  OP_2_16 = (82..96).to_a

  # Does nothing
  def op_nop
  end

  # Duplicates the top stack item.
  def op_dup
    @stack << (@stack[-1].dup rescue @stack[-1])
  end

  # The input is hashed using SHA-256.
  def op_sha256
    buf = @stack.pop
    @stack << Digest::SHA256.digest(buf)
  end

  # The input is hashed using SHA-1.
  def op_sha1
    buf = @stack.pop
    @stack << Digest::SHA1.digest(buf)
  end

  # The input is hashed twice: first with SHA-256 and then with RIPEMD-160.
  def op_hash160
    buf = @stack.pop
    @stack << Digest::RMD160.digest(Digest::SHA256.digest(buf))
  end

  # The input is hashed using RIPEMD-160.
  def op_ripemd160
    buf = @stack.pop
    @stack << Digest::RMD160.digest(buf)
  end

  # The input is hashed two times with SHA-256.
  def op_hash256
    buf = @stack.pop
    @stack << Digest::SHA256.digest(Digest::SHA256.digest(buf))
  end

  # Puts the input onto the top of the alt stack. Removes it from the main stack.
  def op_toaltstack
    @stack_alt << @stack.pop
  end

  # Puts the input onto the top of the main stack. Removes it from the alt stack.
  def op_fromaltstack
    @stack << @stack_alt.pop
  end

  # The item at the top of the stack is copied and inserted before the second-to-top item.
  def op_tuck
    @stack[-2..-1] = [ @stack[-1], *@stack[-2..-1] ]
  end

  # The top two items on the stack are swapped.
  def op_swap
    @stack[-2..-1] = @stack[-2..-1].reverse
  end

  # If both a and b are not 0, the output is 1. Otherwise 0.
  def op_booland
    a, b = @stack.pop(2)
    @stack << (![a,b].any?{|n| n == 0 } ? 1 : 0)
  end

  # a is added to b.
  def op_add
    a, b = @stack.pop(2).reverse
    @stack << a + b
  end

  # b is subtracted from a.
  def op_sub
    a, b = @stack.pop(2).reverse
    @stack << a - b
  end

  # Returns 1 if a is greater than or equal to b, 0 otherwise.
  def op_greaterthanorequal
    a, b = @stack.pop(2).reverse
    @stack << (a >= b ? 1 : 0)
  end

  # Removes the top stack item.
  def op_drop
    @stack.pop
  end

  # Returns 1 if the inputs are exactly equal, 0 otherwise.
  def op_equal
    a, b = @stack.pop(2).reverse
    @stack << (a == b ? 1 : 0)
  end

  # Marks transaction as invalid if top stack value is not true. True is removed, but false is not.
  def op_verify
    res = @stack.pop
    if res != 1
      @stack << res
      @script_invalid = true # raise 'transaction invalid' ?
    else
      @script_invalid = false
    end
  end

  # Same as OP_EQUAL, but runs OP_VERIFY afterward.
  def op_equalverify
    op_equal; op_verify
  end

  # An empty array of bytes is pushed onto the stack.
  def op_0
    @stack << "" # []
  end

  # The number 1 is pushed onto the stack. Same as OP_TRUE
  def op_1
    @stack << 1
  end

  # https://en.bitcoin.it/wiki/BIP_0017  (old OP_NOP2)
  # TODO: don't rely on it yet. add guards from wikipage too.
  def op_checkhashverify
    unless @checkhash && (@checkhash == @stack[-1].unpack("H*")[0])
      @script_invalid = true
    end
  end

  # All of the signature checking words will only match signatures to the data after the most recently-executed OP_CODESEPARATOR.
  def op_codeseparator
    @codehash_start = @chunks.size - @chunks.reverse.index(OP_CODESEPARATOR)
  end

  # do a CHECKSIG operation on the current stack,
  # asking +check_callback+ to do the actual signature verification.
  # This is used by Protocol::Tx#verify_input_signature
  def op_checksig(check_callback)
    return invalid if @stack.size < 2
    pubkey = @stack.pop
    drop_sigs      = [@stack[-1].unpack("H*")[0]]
    sig, hash_type = parse_sig(@stack.pop)

    if @chunks.include?(OP_CHECKHASHVERIFY)
      # Subset of script starting at the most recent codeseparator to OP_CHECKSIG
      script_code, @checkhash = codehash_script(OP_CHECKSIG)
    else
      script_code, drop_sigs = nil, nil
    end

    if check_callback == nil # for tests
      @stack << 1
    else # real signature check callback
      @stack <<
        ((check_callback.call(pubkey, sig, hash_type, drop_sigs, script_code) == true) ? 1 : 0)
    end
  end

  def op_checksigverify(check_callback)
    op_checksig(check_callback)
    op_verify
  end

  # do a CHECKMULTISIG operation on the current stack,
  # asking +check_callback+ to do the actual signature verification.
  #
  # CHECKMULTISIG does a m-of-n signatures verification on scripts of the form:
  #  0 <sig1> <sig2> | 2 <pub1> <pub2> 2 OP_CHECKMULTISIG
  #  0 <sig1> <sig2> | 2 <pub1> <pub2> <pub3> 3 OP_CHECKMULTISIG
  #  0 <sig1> <sig2> <sig3> | 3 <pub1> <pub2> <pub3> 3 OP_CHECKMULTISIG
  #
  # see https://en.bitcoin.it/wiki/BIP_0011 for details.
  # see https://github.com/bitcoin/bitcoin/blob/master/src/script.cpp#L931
  #
  # TODO: validate signature order
  # TODO: take global opcode count
  def op_checkmultisig(check_callback)
    n_pubkeys = @stack.pop
    return invalid  unless (0..20).include?(n_pubkeys)
    return invalid  unless @stack.last(n_pubkeys).all?{|e| e.is_a?(String) && e != '' }
    #return invalid  if ((@op_count ||= 0) += n_pubkeys) > 201
    pubkeys = @stack.pop(n_pubkeys)

    n_sigs = @stack.pop
    return invalid  unless (0..n_pubkeys).include?(n_sigs)
    return invalid  unless @stack.last(n_sigs).all?{|e| e.is_a?(String) && e != '' }
    sigs = (drop_sigs = @stack.pop(n_sigs)).map{|s| parse_sig(s) }

    @stack.pop if @stack[-1] == '' # remove OP_NOP from stack

    if @chunks.include?(OP_CHECKHASHVERIFY)
      # Subset of script starting at the most recent codeseparator to OP_CHECKMULTISIG
      script_code, @checkhash = codehash_script(OP_CHECKMULTISIG)
      drop_sigs.map!{|i| i.unpack("H*")[0] }
    else
      script_code, drop_sigs = nil, nil
    end

    valid_sigs = 0
    sigs.each{|sig, hash_type| pubkeys.each{|pubkey|
        valid_sigs += 1  if check_callback.call(pubkey, sig, hash_type, drop_sigs, script_code)
      }}

    @stack << ((valid_sigs == n_sigs) ? 1 : (invalid; 0))
  end

  OPCODES_METHOD = Hash[*instance_methods.grep(/^op_/).map{|m|
      [ (OPCODES.find{|k,v| v == m.to_s.upcase }.first rescue nil), m ]
    }.flatten]
  OPCODES_METHOD[0]  = :op_0
  OPCODES_METHOD[81] = :op_1

  private

  def parse_sig(sig)
    hash_type = sig[-1].unpack("C")[0]
    sig = sig[0...-1]
    return sig, hash_type
  end

end
