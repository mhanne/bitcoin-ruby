module Bitcoin::Wallet

  # select unspent txouts to be used by the Wallet when creating a new transaction
  class SimpleCoinSelector

    # create coinselector with given +txouts+
    def initialize txouts
      @txouts = txouts
    end

    # select txouts needed to spend +value+ btc (base units)
    def select(value)
      txouts = []
      @txouts.select{|o|o['raw_output_script'] }.each do |txout|
        begin
          txouts << txout
          return txouts  if txouts.map{|o|o['value']}.inject(:+) >= value
        rescue
          p $!
          puts *$@
        end
      end
      nil
    end

  end

end
