require 'socket'

module Moneta
  # Moneta server to be used together with Moneta::Adapters::Client
  # @api public
  class Server
    # @param [Hash] options
    # @option options [Integer] :port (9000) TCP port
    # @option options [String] :socket Alternative Unix socket file name
    def initialize(store, options = {})
      @store = store
      @server = start(options)
      @ios = [@server]
      @clients = {}
      @running = false
    end

    # Is the server running
    #
    # @return [Boolean] true if the server is running
    def running?
      @running
    end

    # Run the server
    #
    # @note This method blocks!
    def run
      raise 'Already running' if @running
      @stop = false
      @running = true
      begin
        mainloop until @stop
      ensure
        File.unlink(@socket) if @socket
        @ios.each { |io| io.close rescue nil }
      end
    end

    # Stop the server
    def stop
      raise 'Not running' unless @running
      @stop = true
      @server.close
      @server = nil
    end

    private

    TIMEOUT = 1
    MAXSIZE = 0x100000

    def mainloop
      if ios = IO.select(@ios, nil, @ios, TIMEOUT)
        ios[2].each do |io|
          io.close
          delete_client(io)
        end
        ios[0].each do |io|
          if io == @server
            if client = @server.accept
              @ios << client
              @clients[client] = ''
            end
          elsif io.closed? || io.eof?
            delete_client(io)
          else
            handle(io, @clients[io] << io.readpartial(0xFFFF))
          end
        end
      end
    rescue SignalException => ex
      warn "Moneta::Server - #{ex.message}"
      raise if ex.signo == 15 || ex.signo == 2 # SIGTERM or SIGINT
    rescue => ex
      warn "Moneta::Server - #{ex.message}"
    end

    def delete_client(io)
      @ios.delete(io)
      @clients.delete(io)
    end

    def pack(obj)
      s = Marshal.dump(obj)
      [s.bytesize].pack('N') << s
    end

    def handle(io, buffer)
      return if buffer.bytesize < 8 # At least 4 bytes for the marshalled array
      size = buffer[0, 4].unpack('N').first
      if size > MAXSIZE
        delete_client(io)
        return
      end
      return if buffer.bytesize < 4 + size
      buffer.slice!(0, 4)
      method, *args = Marshal.load(buffer.slice!(0, size))
      case method
      when :key?, :load, :delete, :increment, :create
        io.write(pack(@store.send(method, *args)))
      when :features
        # all features except each_key are supported
        io.write(pack(@store.features - [:each_key]))
      when :store, :clear
        @store.send(method, *args)
        io.write(@nil ||= pack(nil))
      else
        raise 'Invalid method call'
      end
    rescue IOError => ex
      warn "Moneta::Server - #{ex.message}" unless ex.message =~ /closed/
      delete_client(io)
    rescue => ex
      warn "Moneta::Server - #{ex.message}"
      io.write(pack(Exception.new(ex.message)))
    end

    def start(options)
      if @socket = options[:socket]
        begin
          UNIXServer.open(@socket)
        rescue Errno::EADDRINUSE
          if client = (UNIXSocket.open(@socket) rescue nil)
            client.close
            raise
          end
          File.unlink(@socket)
          tries ||= 0
          (tries += 1) < 3 ? retry : raise
        end
      else
        TCPServer.open(options[:host] || '127.0.0.1', options[:port] || 9000)
      end
    end
  end
end
