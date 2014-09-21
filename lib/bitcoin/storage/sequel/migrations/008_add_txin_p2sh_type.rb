# Add column txin.p2sh_type and index the type of the inner p2sh script of all inputs

Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    if @store.config[:index_p2sh_type]
      puts "Building p2sh type index..."

      add_column @tables[:input], :p2sh_type, :int

      outputs.where(type: 4).each do |txout|
        tx = transactions[id: txout[:tx_id]]
        next  unless next_in = inputs[prev_out: tx[:hash].reverse, prev_out_index: txout[:tx_idx]]
        script = Bitcoin::Script.new(next_in[:script_sig], txout[:pk_script])
        if script.is_p2sh?
          inner_script = Bitcoin::Script.new(script.inner_p2sh_script)
          p2sh_type = @store.class::SCRIPT_TYPES.index(inner_script.type)
          inputs.where(id: next_in[:id]).update(p2sh_type: p2sh_type)
        end

      end

      add_index @tabes[:inputs], [:id, :p2sh_type]

    end
  end

end
