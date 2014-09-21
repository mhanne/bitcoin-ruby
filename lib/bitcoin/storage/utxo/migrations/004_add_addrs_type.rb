# Add column addr.type and correct the type for all p2sh addresses

Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    add_column @tables[:addresses], :type, :int, default: 0, null: false
    add_index @tables[:addresses], [:hash160, :type]

  end

end
