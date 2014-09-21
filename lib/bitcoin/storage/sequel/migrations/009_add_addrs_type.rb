# Add column addr.type and correct the type for all p2sh addresses

Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    add_column @tables[:addresses], :type, :int, default: 0, null: false

    if (count = outputs.where(type: 4).count) > 0
      puts "Fixing address types for #{count} p2sh addresses..."
    end

    i = 0
    # iterate over all txouts with p2sh type
    outputs.where(type: 4).each do |txout|
      # find addr_txout mapping
      addr_txout = address_outputs[txout_id: txout[:id]]

      # find currently linked address
      addr = addresses[id: addr_txout[:addr_id]]

      # skip if address type is already p2sh
      next i+=1  if addr[:type] == 1

      # if address has other txouts, that are not p2sh-type, we need a different one
      if address_outputs.where(addr_id: addr[:id])
          .join(:txout, id: :txout_id).where("type != 4").any?

        # if there is already a corrected address
        if a = addresses[hash160: addr[:hash160], type: 1]
          # use the existing corrected address
          addr_id = a[:id]
        else
          # create new address with correct p2sh type
          addr_id = addresses.insert(hash160: addr[:hash160], type: 1)
        end

        # change mapping to point to new address
        address_outputs.where(txout_id: txout[:id]).update(addr_id: addr_id)

      # if address has only this txout
      else
        # change to correct type
        addresses.where(id: addr[:id]).update(type: 1)
      end

      print "\r#{i}"; i+=1

    end
    puts

    add_index @tables[:addresses], [:hash160, :type]

  end

end
