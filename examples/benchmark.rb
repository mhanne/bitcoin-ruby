#!/usr/bin/env ruby

$:.unshift( File.expand_path("../../lib", __FILE__) )
require 'bitcoin'
require 'timeout'
require 'json'

require_relative "../spec/bitcoin/helpers/fake_blockchain"

# Bitcoin::NETWORKS[:testnet][:proof_of_work_limit] = 553713663
# Bitcoin::NETWORKS[:testnet][:genesis_hash] = "007203b460dfb42af8c58c836bb1414e29c93a7c67502f9c7b1a4369c72577b1"
# Bitcoin.network = :testnet

Bitcoin.network = :testnet3
Bitcoin.network[:proof_of_work_limit] = 0x20ffffff

class Bitcoin::Validation::Block
  def difficulty; true; end
end

def reset
  `rm -rf test.db`
  `echo 'drop database bitcoin_test; create database bitcoin_test;' | psql -p 5433`
#  `echo "drop database bitcoin_test; create database bitcoin_test;" | mysql -uroot -ppassword`
end

def time
  t = Time.now
  yield
  Time.now - t
end

def size
  case @store.db.adapter_scheme
  when :sqlite
    size = File.size("test.db")
  when :postgres
    size = @store.db.fetch("select pg_database_size('bitcoin_test')").first[:pg_database_size]
  when :mysql
    size = @store.db.fetch("select sum(data_length+index_length) from information_schema.tables where table_schema = 'bitcoin_test';").first.to_a[0][1].to_i
  end
end

def run
  @fake_blockchain = FakeBlockchain.new(5)

  time = time do
    5.times {|i| @store.new_block @fake_blockchain.block(i) }
  end

  puts "#{time.to_i.to_s.rjust(5)} | #{size.to_s.rjust(10)} |"
  return [time, size]
rescue Exception
  puts "Error"
  p $!
  return [0, 0]
end


@time, @size = {}, {}

[
#:utxo,
:sequel
].each do |backend|
  puts "Running benchmark on #{backend} backend..."
  reset

  [
#   "sqlite://test.db",
   "postgres://mhanne:password@localhost:5433/bitcoin_test",
#   "mysql://root:password@localhost/bitcoin_test"
  ].each do |db|
    adapter = db.split(":").first
    print "| #{adapter.ljust(8)}  | "
    begin
      @store = Bitcoin::Storage.send(backend, db: db, log_level: :warn)
      time, size = *run
      @store.db.disconnect  unless @store.db.adapter_scheme == :sqlite
    rescue Exception
      time, size = 0, 0
    end
    @time["#{backend}_#{adapter}"] = time
    @size["#{backend}_#{adapter}"] = size
  end
end

File.open("tmp/bench_time.log", "a") do |file|
  file.write "#{ARGV[0] || `git rev-parse HEAD`.strip} #{@time.to_json}\n"
end

File.open("tmp/bench_size.log", "a") do |file|
  file.write "#{ARGV[0] || `git rev-parse HEAD`.strip} #{@size.to_json}\n"
end

