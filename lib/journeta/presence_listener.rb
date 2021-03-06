require 'yaml'
require 'socket'
require 'ipaddr'
require 'journeta/asynchronous'
require 'journeta/peer_connection'

module Journeta
  
  # Uses the fucked up Ruby socket API (which isn't really an API)
  # to listen for presence broadcast from peers. Processing of the
  # inbound data is quickly delegated to a background thread to allow the listener
  # to continue responding to inbound traffic as fast as possible.
  class PresenceListener < Journeta::Asynchronous    
    
    def go
      presence_address = @engine.presence_address
      port = @engine.presence_port
      addresses =  IPAddr.new(presence_address).hton + IPAddr.new("0.0.0.0").hton
      begin
        socket = UDPSocket.new
        # Remember how i said this was fucked up? yeaahhhhhh. i hope you like C.
        # `man setsockopt` for details.
        #
        # The PLATFORM constant got changed to RUBY_PLATFORM in the 1.9 MRI, so we have to handle both cases. :(
        # Also note that jruby 1.3.1 uses PLATFORM.
        if (defined?(PLATFORM) && PLATFORM.match(/linux/i)) || (defined?(RUBY_PLATFORM) && RUBY_PLATFORM.match(/linux/i))
          socket.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, [1].pack("i_") )
        elsif (defined?(PLATFORM) && PLATFORM.match(/java/i)) || (defined?(RUBY_PLATFORM) && RUBY_PLATFORM.match(/java/i))
          socket.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, [1].pack("i_") ) # TODO test this jruby case!
        else
          # SO_REUSEPORT is needed so multiple peers can be run on the same machine.
          # socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_TTL, [1].pack('i')) # Preston's original config for OS X.
          socket.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEPORT, [1].pack("i_") ) # Remi's suggested default.
        end        
        socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, addresses)
        socket.bind(Socket::INADDR_ANY, port)
        putsd "Waiting for presence events."
        loop do
          # Why 1024? umm.. because it's Thursday!
          data, meta = socket.recvfrom 1024
          Thread.new(data, meta) do |data, meta|
            event = YAML.load(data)
            if event.uuid != @engine.uuid
              begin
                m = YAML::load(data)
                peer = PeerConnection.new @engine
                # Why is this always [2]? Not sure.. they should have returned a hash instead.
                peer.ip_address = meta[2]
                peer.peer_port = m.peer_port
                peer.uuid = m.uuid
                peer.version = m.version
                peer.groups = m.groups
                peer.created_at = peer.updated_at = Time.now
              
                # We should not start the #PeerConnection before registering because a running
                # PeerConnection might already be registered. In this case, we'd have wasted a thread,
                # so we'll let the registry handle startup (if it happens at all.)
                #
                # peer.start
              
                # TODO validate peer entry is sane before registering it
                @engine.register_peer peer
              rescue => e
                putsd "Error during peer registration: #{e.message}"
              end
            end
          end
          # putsd "Event received!"
        end
      ensure
        putsd "Closing presence listener socket."
        socket.close
      end
    end
    
  end
  
end