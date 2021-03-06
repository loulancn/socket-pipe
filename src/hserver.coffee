
Net = require 'net'
Event = require 'events'
Http = require 'http'
UUID = require 'node-uuid'
ProxyStream = require './stream/proxy'


endSocket = (socket) ->
    socket.resume()
    socket.end "HTTP/1.1 404 Not Found\r\nContent-Type: text/html;charset=UTF-8\r\n\r\nNotFound"

module.exports = class

    constructor: (@localAddress, @remoteAddress) ->
        @id = 0
        @dataEvent = new Event
        @daemonSockets = {}
        @sockets = {}
        @pipes = {}
        @waits = {}

        setInterval =>
            now = Date.now()

            for uuid, item of @waits
                [hash, buff, time] = item

                if now - time >= 1000
                    item[2] = now

                    if not @pipes[uuid]? and @sockets[uuid]? and @daemonSockets[hash]?
                        @daemonSockets[hash][0].write buff
                        console.info "retry pipe #{uuid}"
        , 200

        @dataEvent.on 'accept', (uuid) =>
            return if not @sockets[uuid]?

            input = new ProxyStream
            @sockets[uuid].push input

            input.setCallback (reqHost, head) =>
                console.info "request #{reqHost}"

                [hash] = reqHost.split '.'
                if not @daemonSockets[hash]?
                    return endSocket @sockets[uuid][0]

                host = if @daemonSockets[hash][1]? then @daemonSockets[hash][1] else reqHost
                buff = new Buffer 4
                buff.writeInt32LE uuid

                console.info "request pipe #{uuid}"
                @daemonSockets[hash][0].write buff

                @waits[uuid] = [hash, buff, Date.now()]

                regex = new RegExp (pregQuote reqHost), 'ig'

                output = new ProxyStream
                output.setFrom host
                output.setTo reqHost

                @sockets[uuid].push output
                @sockets[uuid][0].pause()

                head.replace regex, host

            @sockets[uuid][0].pipe input
            @sockets[uuid][0].resume()

        @dataEvent.on 'pipe', (uuid, hash) =>
            delete @waits[uuid]

            return if not @sockets[uuid]
            return endSocket @sockets[uuid] if not @daemonSockets[hash]
            return endSocket @sockets[uuid] if not @pipes[uuid]

            @sockets[uuid][1].pipe @pipes[uuid]
                .pipe @sockets[uuid][2]
                .pipe @sockets[uuid][0]

            @sockets[uuid][1].release()
            @sockets[uuid][0].resume()
        
        @createLocalServer()
        @createRemoteServer()


    accept: (socket) ->
        console.info "accept #{socket.remoteAddress}:#{socket.remotePort}"
        
        uuid = @id
        @id += 1

        socket.pause()
        @sockets[uuid] = [socket]

        socket.on 'close', =>
            console.info "close socket #{uuid}"
            if @sockets[uuid]?
                delete @sockets[uuid]

            if @waits[uuid]?
                delete @waits[uuid]

        socket.on 'error', console.error
        
        @dataEvent.emit 'accept', uuid


    createRemoteServer: ->
        @remoteServer = Net.createServer (socket) =>
            @accept socket

        @remoteServer.on 'error', console.error
        @remoteServer.listen @remoteAddress.port, @remoteAddress.ip


    createLocalServer: ->
        @localServer = Net.createServer (socket) =>
            connected = no

            socket.on 'error', console.error

            socket.on 'data', (data) =>
                if not connected
                    connected = yes
                    op = data.readInt8 0

                    if op == 1
                        parts = (data.slice 1).toString()
                        items = parts.split '|'
                        [transfer, hash] = items
                        token = if items[2]? then items[2] else null
                        
                        if hash.length == 0 or (@daemonSockets[hash]? and token != @daemonSockets[hash][2])
                            hash = UUID.v1()

                        transfer = null if transfer.length == 0
                        console.info "connected #{socket.remoteAddress}:#{socket.remotePort} = #{hash} #{transfer}"

                        # add token
                        token = UUID.v1()
                        @daemonSockets[hash] = [socket, transfer, token]

                        socket.on 'close', =>
                            delete @daemonSockets[hash] if hash? and @daemonSockets[hash]?

                        socket.write new Buffer hash + '|' + token
                    else if op == 2
                        uuid = data.readInt32LE 1
                        hash = (data.slice 5).toString()

                        return socket.end() if @pipes[uuid]?

                        @pipes[uuid] = socket

                        socket.on 'close', =>
                            console.info "close pipe #{uuid}"

                            if @pipes[uuid]?
                                delete @pipes[uuid]
                        
                        console.info "created pipe #{uuid}"
                        @dataEvent.emit 'pipe', uuid, hash

        @localServer.on 'error', console.error
        @localServer.listen @localAddress.port, @localAddress.ip
    

