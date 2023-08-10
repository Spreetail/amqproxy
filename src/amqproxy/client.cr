require "socket"
require "amq-protocol"
require "./version"

module AMQProxy
  struct Client
    @lock = Mutex.new

    def initialize(@socket : TCPSocket)
    end

    def read_loop(upstream : Upstream)
      socket = @socket
      loop do
        AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian) do |frame|
          case frame
          when AMQ::Protocol::Frame::Heartbeat
            socket.write_bytes frame, IO::ByteFormat::NetworkEndian
            socket.flush
          when AMQ::Protocol::Frame::Connection::CloseOk
            return
          else
            if response_frame = upstream.write frame
              socket.write_bytes response_frame, IO::ByteFormat::NetworkEndian
              socket.flush
              return if response_frame.is_a? AMQ::Protocol::Frame::Connection::CloseOk
            end
          end
        end
      end
    rescue ex : Upstream::WriteError
      upstream_disconnected
    rescue ex : IO::EOFError
      raise Error.new("Client disconnected", ex) unless @socket.closed?
    rescue ex
      raise ReadError.new "Client read error", ex
    ensure
      @socket.close rescue nil
    end

    # Send frame to client
    def write(frame : AMQ::Protocol::Frame)
      @lock.synchronize do
        socket = @socket
        return if socket.closed?
        frame.to_io(socket, IO::ByteFormat::NetworkEndian)
        socket.flush
        case frame
        when AMQ::Protocol::Frame::Connection::CloseOk
          socket.close
        end
      end
    rescue ex : Socket::Error
      raise WriteError.new "Error writing to client", ex
    end

    def upstream_disconnected
      write AMQ::Protocol::Frame::Connection::Close.new(0_u16,
        "UPSTREAM_ERROR",
        0_u16, 0_u16)
    rescue WriteError
    end

    def close
      write AMQ::Protocol::Frame::Connection::Close.new(0_u16,
        "AMQProxy shutdown",
        0_u16, 0_u16)
    end

    def close_socket
      @socket.close rescue nil
    end

    def self.negotiate(socket)
      proto = uninitialized UInt8[8]
      socket.read_fully(proto.to_slice)

      if proto != AMQ::Protocol::PROTOCOL_START_0_9_1 && proto != AMQ::Protocol::PROTOCOL_START_0_9
        socket.write AMQ::Protocol::PROTOCOL_START_0_9_1.to_slice
        socket.flush
        socket.close
        raise IO::EOFError.new("Invalid protocol start")
      end

      props = AMQ::Protocol::Table.new({
        product:      "AMQProxy",
        version:      VERSION,
        capabilities: {
          consumer_priorities:          true,
          exchange_exchange_bindings:   true,
          "connection.blocked":         true,
          authentication_failure_close: true,
          per_consumer_qos:             true,
          "basic.nack":                 true,
          direct_reply_to:              true,
          publisher_confirms:           true,
          consumer_cancel_notify:       true,
        },
      })
      start = AMQ::Protocol::Frame::Connection::Start.new(server_properties: props)
      start.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      user = password = ""
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian) do |frame|
        start_ok = frame.as(AMQ::Protocol::Frame::Connection::StartOk)
        case start_ok.mechanism
        when "PLAIN"
          resp = start_ok.response
          if i = resp.index('\u0000', 1)
            user = resp[1...i]
            password = resp[(i + 1)..-1]
          else
            raise "Invalid authentication information encoding"
          end
        when "AMQPLAIN"
          io = IO::Memory.new(start_ok.response)
          tbl = AMQ::Protocol::Table.from_io(io, IO::ByteFormat::NetworkEndian,
            start_ok.response.size.to_u32)
          user = tbl["LOGIN"].as(String)
          password = tbl["PASSWORD"].as(String)
        else raise "Unsupported authentication mechanism: #{start_ok.mechanism}"
        end
      end

      tune = AMQ::Protocol::Frame::Connection::Tune.new(frame_max: 131072_u32, channel_max: 0_u16, heartbeat: 0_u16)
      tune.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      AMQ::Protocol::Frame.from_io socket, IO::ByteFormat::NetworkEndian do |_tune_ok|
      end

      vhost = ""
      AMQ::Protocol::Frame.from_io(socket, IO::ByteFormat::NetworkEndian) do |frame|
        open = frame.as(AMQ::Protocol::Frame::Connection::Open)
        vhost = open.vhost
      end

      open_ok = AMQ::Protocol::Frame::Connection::OpenOk.new
      open_ok.to_io(socket, IO::ByteFormat::NetworkEndian)
      socket.flush

      {vhost, user, password}
    rescue ex
      raise NegotiationError.new "Client negotiation failed", ex
    end

    class Error < Exception; end

    class ReadError < Error; end

    class WriteError < Error; end

    class NegotiationError < Error; end
  end
end
