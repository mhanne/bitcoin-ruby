$:.unshift( File.expand_path("../../lib", __FILE__) )
require 'bitcoin'

Bitcoin.network = :testnet3

s = Bitcoin::Storage.sequel(db: "postgres:/testnet3", log_level: 0)

File.open("blockchain_headers", "wb") do |file|

  (0..s.get_depth).each_slice(2016) do |slice|
    p slice[0]
    file.write s.db[:blk].where(chain: 0, depth: slice).map {|b|
      [ b[:version], b[:prev_hash].reverse, b[:mrkl_root].reverse,
        b[:time], b[:bits], b[:nonce] ].pack("Ia32a32III")
    }.join
  end

end
