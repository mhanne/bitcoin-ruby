# Add column addr.type and correct the type for all p2sh addresses

Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    rename_column @tables[:blocks], :depth, :height

  end

end
