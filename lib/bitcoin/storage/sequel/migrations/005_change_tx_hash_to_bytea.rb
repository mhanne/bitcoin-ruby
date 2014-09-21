Sequel.migration do

  up do

    @log.info { "Running migration #{__FILE__}" }

    if adapter_scheme == :postgres
      execute "DROP VIEW unconfirmed"  if self.views.include?(:unconfirmed)
      execute "ALTER TABLE #{@tables[:transactions]} ALTER COLUMN hash TYPE bytea USING hash::bytea"
    end

  end

end
