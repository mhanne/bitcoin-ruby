Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    if adapter_scheme == :postgres
      add_column @tables[:inputs], :tmp_prev_out, :bytea
      inputs.where.update("tmp_prev_out = prev_out::bytea")
      drop_column @tables[:inputs], :prev_out
      add_column @tables[:inputs], :prev_out, :bytea, index: true
      inputs.where.update("prev_out = tmp_prev_out")
      drop_column @tables[:inputs], :tmp_prev_out
    end

  end

end
