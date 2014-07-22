#!/usr/bin/env ruby
# 
# Collect all unspent outputs for given address and display balance.
# Optionally display list of transactions.
# 
#  examples/balance.rb <address> [--list]
#  examples/balance.rb 1Q2TWHE3GMdB6BZKafqwxXtWAWgFt5Jvm3

$:.unshift( File.expand_path("../../lib", __FILE__) )
require 'bitcoin'

Bitcoin.network = :bitcoin
store = Bitcoin::Storage.sequel(:db => "sqlite://bitcoin.db")

address = ARGV.shift

unless Bitcoin.valid_address?(address)
  puts "Address #{address} is invalid for #{Bitcoin.network_name} network."
  exit 1
end


# format value to be displayed
def str_val(val, pre = "")
  ("#{pre}#{"%.8f" % (val / 1e8)}").rjust(20)
end

if ARGV[0] == "--list"
  txouts = store.txouts_for_address(address)
  unless txouts.any?
    puts "Address not seen."
    exit
  end

  total = 0
  txouts.each do |txout|
    tx = txout.tx
    total += txout.value
    puts "#{tx.hash} |#{str_val(txout.value, '+ ')}  |=> #{str_val(total)}"

    tx = txout.tx
    if tx.is_coinbase?
      puts " "*12 + "generated (#{tx.block.hash})"
    else
      tx.in.each do |txin|
        addresses = txin.prev_out.get_addresses.join(", ")
        puts "  #{str_val(txin.prev_out.value)} from #{addresses}"
      end
    end
    puts

    if txin = txout.next_in
      tx = txin.tx
      total -= txout.value
      puts "#{tx.hash} |#{str_val(txout.value, '- ')}  |=> #{str_val(total)}"
      txin.tx.out.each do |out|
        puts "  #{str_val(out.value)} to #{out.get_addresses.join(", ")}"
      end
      puts
    end
  end
end

hash160 = Bitcoin.hash160_from_address(address)
balance = store.balance(hash160)
puts "Balance: %.8f" % (balance / 1e8)
