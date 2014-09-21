Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    if adapter_scheme == :postgres
      add_column @tables[:inputs], :tmp_script_sig, :bytea
      inputs.where.update("tmp_script_sig = script_sig::bytea")
      drop_column @tables[:inputs], :script_sig
      add_column @tables[:inputs], :script_sig, :bytea
      inputs.where.update("script_sig = tmp_script_sig")
      drop_column @tables[:inputs], :tmp_script_sig
    end

  end

end
