# encoding: ascii-8bit

require_relative '../spec_helper'
require 'benchmark'

describe "Script parser" do

  before do
    @scripts = [
      "304402202946d644a8171ae9656891af891253e0af340e7974cdcf01b9794b657b34b9370220637b2871da11c8dafb9cb4c58a93cca02d3f06ba67fe0219c9a5e20c2a61da310102e0a9ddfa071880064c7651469c8adadf0693efdc6aedf6a6585e685008e10e55 OP_DUP OP_HASH160 fa8ddb8071cf3381840514937b5f0a212113adac OP_EQUALVERIFY OP_CHECKSIG", # to address
      "0 3046022100be993e6f5ce06297664b6c1d4bd388eb9d6f6f9cd064f7513af7138d0516dca20221008e6fe8caacd3ce94e8f10e9ef721dab5ba849748fdd43fb3cafcbb3d45e6e70501 304502202e572b293e72da0978d1d9a68bddd47cc98f6a960ada19e3fb260588671e7600022100bafbde2d23f1199ce5d2b1f25ae5e150ee0a2dc85923cde383a56c6d22b1827901 76:105:5221022a30c0841ae8e47c1c5e13632d0de3c872884288a151040313ce098c9af6c37b21036520e28b87078f0c015e598cac55b24abbd14749db1589bc790c21046daa7be321024e9820413173c89d8abe4fb9564cec434899183cd2a39eada2074e49bd3d902453ae OP_HASH160 1b3aea0f2519dc33430243a7338ad3665ed131fd OP_EQUAL" # p2sh multisig
    ].map {|s| Bitcoin::Script.from_string(s).raw }
  end

  it "parse script" do
    n = 100_000
    bm = Benchmark.measure do
      bm = Benchmark.bm do |b|
        b.report("p2kh: ") do
          n.times { Bitcoin::Script.new(@scripts[0]) }
        end
        b.report("p2sh: ") do
          n.times { Bitcoin::Script.new(@scripts[1]) }
        end
      end
    end
    true.should == true
  end
end
