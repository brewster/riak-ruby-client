module Riak
  class Client
    class ProtobuffsBackend
      # A factory class for making sockets, whether secure or not
      # @api private
      class ProtobuffsSocket
        include BeefcakeMessageCodes
        # Only create class methods, don't initialize
        class << self
          def new(host, port, options={})
            return start_tcp_socket(host, port) unless options[:authentication]
          end

          private
          def start_tcp_socket(host, port)
            TCPSocket.new(host, port).tap do |sock|
              sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
            end
          end

          def start_tls_socket(host, port, authentication)
            TlsInitiator.new(start_tcp_socket(host, port)).tls_socket
          end
          
          # Wrap up the logic to turn a TCP socket into a TLS socket.
          # Depends on Beefcake, which should be relatively safe.
          class TlsInitiator
            BC = BeefcakeProtobuffsBackend

            # Create a TLS Initiator
            #
            # @param tcp_socket [TCPSocket] the {TCPSocket} to start TLS on
            # @param authentication [Hash] a hash of authentication details
            def initialize(tcp_socket, authentication)
              @sock = @tcp = tcp_socket
              @auth = authentication
            end

            # Return the SSLSocket that has a TLS session running. (TLS is a
            # better and safer SSL).
            #
            # @return [OpenSSL::SSL::SSLSocket]
            def tls_socket
              start_tls
              send_authentication
              validate_connection
              return @tls
            end

            private
            # Attempt to exchange the TCP socket for a TLS socket.
            def start_tls
              write_message :StartTls
              expect_message :StartTls
              # Swap the tls socket in for the tcp socket, so write_message and
              # read_message continue working
              @sock = @tls = OpenSSL::SSL::SSLSocket.new @tcp
              @tls.connect
            end

            # Send an AuthReq with the authentication data. Rely on beefcake
            # discarding message parts it doesn't understand.
            def send_authentication
              req = BC::RpbAuthReq authentication
              write_message :AuthReq, req.encode
              expect_message :AuthResp
            end

            # Ping the Riak node and make sure it actually works.
            def validate_connection
              write_message :PingReq
              expect_message :PingResp
            end

            # Write a protocol buffers message to whatever the current
            # socket is.
            def write_message(code, message='')
              if code.is_a? Symbol
                code = BeefcakeMessageCodes.index code
              end

              header = [message.length+1, code].pack 'NC'
              @sock.write header + message
            end

            def read_message
              header = @sock.read 5
              raise SocketError, "Unexpected EOF during TLS init" if header.nil?
              len, code = header.unpack 'NC'
              decode = BeefcakeMessageCodes[code]
              return decode, '' if len == 1
              
              message = socket.read(len - 1)
              return decode, message
            end

            def expect_message(expected_code)
              if expected_code.is_a? Numeric
                expected_code = BeefcakeMessageCodes[code]
              end

              candidate_code, message = read_message
              return message if expected_code == candidate_code

              raise "Wanted #{expected_code.inspect}, got #{candidate_code.inspect} and #{message.inspect}"
            end
          end
        end
      end
    end
  end
end
