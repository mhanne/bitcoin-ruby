require_relative 'spec_helper'

describe "Bitcoin::Key" do

  before do
    @key_data = {
      :priv => "2ebd3738f59ae4fd408d717bf325b4cb979a409b0153f6d3b4b91cdfe046fb1e",
      :pub => "045fcb2fb2802b024f371cc22bc392268cc579e47e7936e0d1f05064e6e1103b8a81954eb6d3d33b8b6e73e9269013e843e83919f7ce4039bb046517a0cad5a3b1" }
    @key = Bitcoin::Key.new(@key_data[:priv], @key_data[:pub])
  end

  it "should generate a key" do
    k = Bitcoin::Key.generate
    k.priv.size.should == 64
    k.pub.size.should == 130
    #p k.priv, k.pub
  end

  it "should create empty key" do
    k = Bitcoin::Key.new
    k.priv.should == nil
    k.pub.should == nil
  end

  it "should create key from priv + pub" do
    k = Bitcoin::Key.new(@key_data[:priv], @key_data[:pub])
    k.priv.should == @key_data[:priv]
    k.pub.should == @key_data[:pub]
  end

  it "should create key from only priv" do
    k = Bitcoin::Key.new(@key_data[:priv])
    k.priv.should == @key_data[:priv]
    k.pub.should == @key_data[:pub]
  end

  it "should create key from only pub" do
    k = Bitcoin::Key.new(nil, @key_data[:pub])
    k.pub.should == @key_data[:pub]
  end

  it "should set public key" do
    k = Bitcoin::Key.new
    k.pub = @key_data[:pub]
    k.pub.should == @key_data[:pub]
  end

  it "should set private key" do
    k = Bitcoin::Key.new
    k.priv = @key_data[:priv]
    k.priv.should == @key_data[:priv]
    k.pub.should == @key_data[:pub]
  end

  it "should get addr" do
    @key.addr.should == "1JbYZRKyysprVjSSBobs8LX6QVjzsscQNU"
  end

  it "should sign data" do
    @key.sign("foobar").size.should >= 69
  end

  it "should verify signature" do
    sig = @key.sign("foobar")
    key2 = Bitcoin::Key.new(nil, @key.pub)
    @key.verify("foobar", sig).should == true
  end

  it "should export private key in base58 format" do
    Bitcoin.network = :bitcoin
    str = Bitcoin::Key.new("e9873d79c6d87dc0fb6a5778633389f4453213303da61f20bd67fc233aa33262").to_base58
    str.should == "5Kb8kLf9zgWQnogidDA76MzPL6TsZZY36hWXMssSzNydYXYB9KF"
    Bitcoin.network = :testnet
    str = Bitcoin::Key.new("d21fa2c7ad710ffcd9bcc22a9f96357bda1a2521ca7181dd610140ecea2cecd8").to_base58
    str.should == "93BTVFoqffueSaC5fqjLjLyn29S41JzvAZm2hC35SYMoYDXT1bY"
    Bitcoin.network = :bitcoin
  end

  it "should import private key in base58 format" do
    Bitcoin.network = :bitcoin
    key = Bitcoin::Key.from_base58("5Kb8kLf9zgWQnogidDA76MzPL6TsZZY36hWXMssSzNydYXYB9KF")
    key.priv.should == "e9873d79c6d87dc0fb6a5778633389f4453213303da61f20bd67fc233aa33262"
    key.addr.should == "1CC3X2gu58d6wXUWMffpuzN9JAfTUWu4Kj"
    Bitcoin.network = :testnet
    key = Bitcoin::Key.from_base58("93BTVFoqffueSaC5fqjLjLyn29S41JzvAZm2hC35SYMoYDXT1bY")
    key.priv.should == "d21fa2c7ad710ffcd9bcc22a9f96357bda1a2521ca7181dd610140ecea2cecd8"
    key.addr.should == "n3eH91H14mSnGx4Va2ngtLFCeLPRyYymRg"
    Bitcoin.network = :bitcoin
  end

end
