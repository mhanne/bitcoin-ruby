require_relative 'spec_helper.rb'

describe 'Bitcoin::Validator' do

  before do
    @tx = Bitcoin::Protocol::Tx.new( fixtures_file('rawtx-f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16.bin') )
    @prev_tx = Bitcoin::Protocol::Tx.new( fixtures_file('rawtx-0437cd7f8525ceed2324359c2d0ba26006d92d856a9c20fa0241106ee5a597c9.bin') )

    @store = Bitcoin::Storage.dummy({})
    @store.store_tx(@prev_tx)
  end

  def validate(in_tx)
    validator = Bitcoin::TxValidator.new(@store, in_tx)
    validator.validate.should == true
  end

  def assert_error(message, &block)
    proc { block.call }.should.raise(Bitcoin::ValidationError).message.should == message
  end

  it "should validate" do
    validate(@tx).should == true
  end

#  it "should not validate if syntax is incorrect"

  it "should not validate if in list empty" do
    @tx.instance_eval { @in = [] }
    assert_error("in_out_size") { validate(@tx) }
  end

  it "should not validate if out list empty" do
    @tx.instance_eval { @out = [] }
    assert_error("in_out_size") { validate(@tx) }
  end

  it "should not validate if too lange" do
    @tx.instance_eval do
      def @payload.bytesize
        1_000_001
      end
    end
    assert_error("size") { validate(@tx) }
  end

  it "should not validate if output total is outside legal money range" do
    @tx.out[0].value = 20_000_000_000_000_00
    @tx.out[1].value = 2_000_000_000_000_00
    assert_error("money_range") { validate(@tx) }
  end

#  it "should not validate if tx references coinbase tx" do
#    # TODO: ???
#  end

  it "should not validate if locktime is too high" do
    @tx.lock_time = 4294967296
    assert_error("lock_time") { validate(@tx) }
  end

  it "should not validate if tx is too small (to possibly do anything useful)" do
    @tx.instance_eval do
      def @payload.bytesize
        99
      end
    end
    assert_error("min_size") { validate(@tx) }
  end

#  it "should not validate if sig opcount > 2" do
#    # TODO: ???
#  end

  it "should not validate duplicate transaction" do
    @store.store_tx(@tx)
    assert_error("no_duplicate") { validate(@tx) }
  end

  it "should not validate transaction with invalid signatures" do
    @tx.in[0].script_sig[5..10] = "foobar"
    assert_error("signatures") { validate(@tx) }
  end

end
