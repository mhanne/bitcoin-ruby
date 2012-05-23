module Bitcoin
  module Protocol

    class Version < Struct.new(:version, :services, :timestamp, :to, :from,
        :nonce, :user_agent, :block)

      SERVICES = [:network, :service, :stratized]

      #
      # parse packet
      #
      def self.parse(payload)
        version, services, timestamp, to, from, nonce, payload = payload.unpack("IQQa26a26Qa*")
        services = SERVICES.select.with_index {|s, i| (services & (1 << i)) != 0 }
        user_agent, payload = Protocol.unpack_var_string(payload)
        block = payload.unpack("I")[0]
        to, from = parse_ip(to), parse_ip(from)
        new(version, services, timestamp, to, from, nonce, user_agent, block)
      end

      def self.parse_ip(payload)
        service, ip, port = payload.unpack("Qx12a4n")
        { :service => service, :ip => ip.unpack("C*"), :port => port }
      end

      #
      # build packet
      #
      def self.build_address(addr_str)
        host, port = addr_str.split(":")
        port = port ? port.to_i : 8333
        sockaddr = Socket.pack_sockaddr_in(port, host)
        #raise "invalid IPv4 Address: #{addr}" unless sockaddr[0...2] == "\x02\x00"
        port, host = sockaddr[2...4], sockaddr[4...8]
        [[1].pack("Q"), "\x00"*10, "\xFF\xFF",  host, port].join
      end

      def self.build_payload(from_id, from, to, opts = {})
        opts = {:version => Bitcoin::Protocol::VERSION, :services => [],
          :block => 0, :time => Time.now.tv_sec,
          :user_agent => "/bitcoin-ruby:#{Bitcoin::VERSION}/"}.merge(opts)
        services = opts[:services].map{|i| (1 << SERVICES.index(i)) }.inject(:|)
        payload = [
          [opts[:version], services, opts[:time]].pack("IQQ"),
          build_address(from), build_address(to),
          [from_id].pack("Q"),
          Protocol.pack_var_string(opts[:user_agent]),
          [opts[:block]].pack("I")
        ].join
      end
    end

  end
end
