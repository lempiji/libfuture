import std.stdio;
import std.socket;

import core.thread;
import core.time;

import libfuture;

void main()
{
    auto address = new InternetAddress("localhost", 8080);

    auto listener = new TcpSocket();
    assert(listener.isAlive);
    listener.blocking = false;
    listener.bind(address);
    listener.listen(10);
    writefln!"Listening %s..."(address);

    EventLoop runner;

    auto acceptThread = new Fiber({
        for (;;)
        {
            auto socket = listener.acceptAsync().await;

            runner.schedule(new Fiber({
                scope (exit) socket.close();
                for (;;)
                {
                    auto request = socket.receiveAsync().await;
                    if (request.length == 0)
                    {
                        writeln("server: client disconnected.");
                        return;
                    }
                    writefln!"server: receive '%s'"(request);
                    socket.sendAsync(request).await;
                }
            }));
        }
    });

    auto clientThread = new Fiber({
        auto client = new TcpSocket();
        client.blocking = false;

        client.connect(address);
        scope (exit)
            client.close();

        foreach (i; 0 .. 3)
        {
            import std.format : format;

            auto text = format!"Hello, server! (%d)"(i);

            client.sendAsync(text).await;
            auto response = client.receiveAsync().await;
            assert(response == text);

            writefln!"client: receive '%s'"(response);
        }
    });

    runner.schedule(acceptThread);
    runner.schedule(clientThread);
    runner.run();
}


Future!Socket acceptAsync(Socket server)
{
    assert(!server.blocking);

    return new Future!Socket({
        canReceive(server).await;
        return server.accept();
    });
}

Future!string receiveAsync(Socket socket)
{
    assert(!socket.blocking);

    return new Future!string({
        import std.array : appender;

        auto buf = appender!string;
        for (;;)
        {
            socket.canReceive().await;

            enum BUF_SIZE = 4096;
            char[BUF_SIZE] tempBuf;
            const len = socket.receive(tempBuf[]);
            if (len <= 0)
                return buf.data;

            if (len == BUF_SIZE)
            {
                buf.put(tempBuf[]);
                continue;
            }
            buf.put(tempBuf[0 .. len]);
            return buf.data;
        }
    });
}

Fiber sendAsync(Socket socket, string data)
{
    assert(!socket.blocking);

    return new Fiber({
        while (data.length > 0)
        {
            socket.canSend().await;

            const len = socket.send(data);
            if (len > 0)
            {
                data = data[len .. $];
            }
        }
    });
}

Fiber canReceive(Socket socket)
{
    return new Fiber({
        auto socketSet = new SocketSet(1);
        for (;;)
        {
            socketSet.add(socket);
            const n = Socket.select(socketSet, null, null, Duration.zero);
            if (n != -1 && socketSet.isSet(socket))
                break;
            Fiber.yield();
            socketSet.reset();
        }
    });
}

Fiber canSend(Socket socket)
{
    return new Fiber({
        auto socketSet = new SocketSet(1);
        for (;;)
        {
            socketSet.add(socket);
            const n = Socket.select(null, socketSet, null, Duration.zero);
            if (n != -1 && socketSet.isSet(socket))
                break;
            Fiber.yield();
            socketSet.reset();
        }
    });
}
