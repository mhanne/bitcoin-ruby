Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    def process_block blk
      print "\r#{blk.hash} - #{blk.depth}"
      blk.tx.each do |tx|
        transactions.where(hash: tx.hash.htb.blob).update(nhash: tx.nhash.htb.blob)
      end
    end

    if @store.config[:index_nhash]
      puts "Building normalized hash index..."

      add_column @tables[:transactions], :nhash, :bytea

      next  unless b = blocks[depth: 0, chain: 0]
      if blk = @store.block(b[:hash].hth)
        process_block(blk)
        while blk = blk.next_block
          process_block(blk)
        end
      end

      add_index @tables[:transactions], :nhash

    end
  end

end
