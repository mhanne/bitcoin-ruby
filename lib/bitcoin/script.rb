require 'bitcoin'

module Bitcoin

  class Script

    include Bitcoin::Opcodes

    attr_reader :raw, :chunks, :debug

    # create a new script. +bytes+ is typically input_script + output_script
    def initialize(bytes, offset=0)
      @raw = bytes
      @stack, @stack_alt = [], []
      @chunks = parse(bytes, offset)
    end

    # parse raw script
    def parse(bytes, offset=0)
      program = bytes.unpack("C*")
      chunks = []
      until program.empty?
        opcode = program.shift(1)[0]
        if opcode >= 0xf0
          opcode = (opcode << 8) | program.shift(1)[0]
        end

        if (opcode > 0) && (opcode < OP_PUSHDATA1)
          len = opcode
          chunks << program.shift(len).pack("C*")
        elsif (opcode == OP_PUSHDATA1)
          len = program.shift(1)[0]
          chunks << program.shift(len).pack("C*")
        elsif (opcode == OP_PUSHDATA2)
          len = program.shift(2).pack("C*").unpack("n")[0]
          chunks << program.shift(len).pack("C*")
        elsif (opcode == OP_PUSHDATA4)
          len = program.shift(4).pack("C*").unpack("N")[0]
          chunks << program.shift(len).pack("C*")
        else
          chunks << opcode
        end
      end
      chunks
    end

    # string representation of the script
    def to_string(chunks=nil)
      (chunks || @chunks).map{|i|
        case i
        when Fixnum
          case i
          when *OPCODES.keys;          OPCODES[i]
          when *OP_2_16;               (OP_2_16.index(i)+2).to_s
          else "(opcode #{i})"
          end
        when String
          i.unpack("H*")[0]
        end
      }.join(" ")
    end

    # script object of a string representation
    def self.from_string(script_string)
      new(binary_from_string(script_string))
    end

    # raw script binary of a string representation
    def self.binary_from_string(script_string)
      script_string.split(" ").map{|i|
        case i
        when *OPCODES.values;          OPCODES.find{|k,v| v == i }.first
        when *OPCODES_ALIAS.keys;      OPCODES_ALIAS.find{|k,v| k == i }.last
        when /^([2-9]$|1[0-7])$/;      OP_2_16[$1.to_i-2]
        when /\(opcode (\d+)\)/;       $1.to_i
        else
          data = [i].pack("H*")
          size = data.bytesize

          head = if size < OP_PUSHDATA1
                   [size].pack("C")
                 elsif size > OP_PUSHDATA1 && size <= 0xff
                   [OP_PUSHDATA1, size].pack("CC")
                 elsif size > 0xff && size <= 0xffff
                   [OP_PUSHDATA2, size].pack("Cn")
                 elsif size > 0xffff && size <= 0xffffffff
                   [OP_PUSHDATA4, size].pack("CN")
                 end

          head + data
        end
      }.map{|i|
        i.is_a?(Fixnum) ? [i].pack("C*") : i # TODO yikes, implement/pack 2 byte opcodes.
      }.join
    end

    def invalid?
      @script_invalid ||= false
    end



    # run the script. +check_callback+ is called for OP_CHECKSIG operations
    def run(&check_callback)
      @debug = []
      @chunks.each{|chunk|
        break if invalid?
        @debug << @stack.map{|i| i.unpack("H*") rescue i}
        case chunk
        when Fixnum
          case chunk

          when *OPCODES_METHOD.keys
            m = method( n=OPCODES_METHOD[chunk] )
            @debug << n.to_s.upcase
            (m.arity == 1) ? m.call(check_callback) : m.call  # invoke opcode method

          when *OP_2_16
            @stack << OP_2_16.index(chunk) + 2
            @debug << "OP_#{chunk-80}"
          else
            name = OPCODES[chunk] || chunk
            raise "opcode #{name} unkown or not implemented"
          end
        when String
          @debug << "PUSH DATA #{chunk.unpack("H*")[0]}"
          @stack << chunk
        end
      }
      @debug << @stack.map{|i| i.unpack("H*") rescue i }

      if @script_invalid
        @stack << 0
        @debug << "INVALID TRANSACTION"
        #require 'pp'; pp @debug
      end

      @debug << "RESULT"
      @stack.pop == 1
    end

    def invalid
      @script_invalid = true; nil
    end

    def codehash_script(opcode)
      # CScript scriptCode(pbegincodehash, pend);
      script    = to_string(@chunks[(@codehash_start||0)...@chunks.size-@chunks.reverse.index(opcode)])
      checkhash = Bitcoin.hash160(Bitcoin::Script.binary_from_string(script).unpack("H*")[0])
      [script, checkhash]
    end

    def self.drop_signatures(script_pubkey, drop_signatures)
      script = new(script_pubkey).to_string.split(" ").delete_if{|c| drop_signatures.include?(c) }.join(" ")
      script_pubkey = binary_from_string(script)
    end

    # Script type definitions used to create scripts an determine script type.
    # Defines the order in which data and opcodes are expected.
    #
    # Alternative options can be given as an array.
    #
    # A String means "that many bytes of data". If the number is prefixed with +?+,
    # the element is optional, meaning if the input element doesn't match,
    # it is ignored and the compared to the next definition element.
    TYPES = {
      :pubkey => ["65", OP_CHECKSIG],
      :address => [OP_DUP, OP_HASH160, "20", OP_EQUALVERIFY, OP_CHECKSIG],
      :multisig => [[OP_1, 82, 83], "65", "65", "?65", [82, 83], OP_CHECKMULTISIG],
    }

    # Match an opcode definition +match+ to given opcode +op+.
    def self.match_opcode(match, op)
      if match.is_a?(Array)
        return match.map {|m| match_opcode(m, op)}.any?
      elsif match.is_a?(String)
        if match[0] == "?"
          match = match[1..-1]
          return :omit  unless op.is_a?(String)
        end
        return false  unless op.is_a?(String)
        return false  unless op.bytesize == match.to_i
      else
        return false  unless op == match
      end
      true
    end

    # Check if script matches given +type+.
    def is_type?(type)
      i = 0
      TYPES[type.to_sym].each do |c|
        if !match = self.class.match_opcode(c, @chunks[i])
          return false
        elsif match != :omit
          i += 1
        end
      end
      true
    end


    # Create script of type +type+ using given data.
    # Take opcodes from the script definition and insert +args+ for
    # the data elements, while checking that it matches defined size.
    def self.to_script(type, *args)
      i, script = 0, new("")
      TYPES[type.to_sym].each do |c|
        if c.is_a?(Fixnum)
          script.chunks[i] = c
          next i += 1
        end
        val = args[0]
        if c.is_a?(Array)
          raise "error: expected #{c} opcode, got #{val}"  unless match_opcode(c, val)
        elsif c.is_a?(String)
          if c[0] == "?"
            next  unless val.is_a?(String)  # skip optional data element
            c = c[1..-1]
          end
          raise "error: expected #{c} bytes of data, got #{val.bytesize}"  if val.bytesize != c.to_i
        end
        script.chunks[i] = args.shift
        i += 1
      end
      from_string(script.to_string)
    end

    def method_missing(name, *args)
      if name =~ /^is_(.*?)\?/ && TYPES.keys.include?($1.to_sym)
        return is_type?($1, *args)
      end
      super(name, *args)
    end

    def self.method_missing(name, *args)
      if name =~ /^(.*?)_script/ && TYPES.keys.include?($1.to_sym)
        return to_script($1, *args)
      end
      super(name, *args)
    end

    # check if script is in one of the recognized standard formats
    def is_standard?
      TYPES.keys.map{|t| is_type?(t)}.any?
    end

    # Alias for #is_address?
    def is_hash160?
      is_type?(:address)
    end

    # get the public key for this script (in generation scripts)
    def get_pubkey
      return @chunks[0].unpack("H*")[0] if @chunks.size == 1
      is_pubkey? ? @chunks[0].unpack("H*")[0] : nil
    end

    # get the address for the public key (in generation scripts)
    def get_pubkey_address
      Bitcoin.pubkey_to_address(get_pubkey)
    end

    def get_multisig_addresses
      pubs = 0.upto(@chunks[0] - 80).map {|i| @chunks[i+1]}
      pubs.map {|p| Bitcoin::Key.new(nil, p.unpack("H*")[0]).addr}
    end

    # get the hash160 for this script (in standard address scripts)
    def get_hash160
      return @chunks[2..-3][0].unpack("H*")[0]  if is_hash160?
      return Bitcoin.hash160(get_pubkey)        if is_pubkey?
    end

    # get the address for the script hash160 (in standard address scripts)
    def get_hash160_address
      Bitcoin.hash160_to_address(get_hash160)
    end

    # get all addresses this script corresponds to (if possible)
    def get_addresses
      return [get_pubkey_address]  if is_pubkey?
      return [get_hash160_address] if is_hash160?
      return get_multisig_addresses  if is_multisig?
    end

    # get single address, or first for multisig script
    def get_address
      addrs = get_addresses
      addrs.is_a?(Array) ? addrs[0] : addrs
    end

    # generate standard transaction script for given +address+
    def self.to_address_script(address)
      hash160 = Bitcoin.hash160_from_address(address)
      return nil  unless hash160
      return to_script(:address, [hash160].pack("H*")).raw
    end

    def self.to_signature_pubkey_script(signature, pubkey)
      hash_type = "\x01"
      #pubkey = [pubkey].pack("H*") if pubkey.bytesize != 65
      raise "pubkey is not in binary form" unless pubkey.bytesize == 65  && pubkey[0] == "\x04"
      [ [signature.bytesize+1].pack("C"), signature, hash_type, [pubkey.bytesize].pack("C"), pubkey ].join
    end

  end
end
