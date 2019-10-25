module agora.common.Channel;

import agora.common.Queue;

import core.thread;

public class SimpleChannel (T)
{
    private NonBlockingQueue!T queue;
    private bool closed;

    public this ()
    {
        this.queue = new NonBlockingQueue!T;
    }

    public ~this ()
    {
        this.queue.close();
    }

    public @property bool isClosed ()
    {
        return this.queue.isClosed;
    }

    public void send (T data)
    {
        this.queue.enqueue(data);
    }

    public T receive ()
    {
        return this.queue.dequeue();
    }

    public void close ()
    {
        this.queue.close();
    }
}

private struct SudoFiber (T)
{
    public Fiber fiber;
    public T* elem_ptr;
    public T  elem;
}

public class Channel (T)
{
    private bool closed;
    private NonBlockingQueue!T queue;
    private NonBlockingQueue!(SudoFiber!(T)) sendq;
    private NonBlockingQueue!(SudoFiber!(T)) recvq;

    public this ()
    {
        this.queue = new NonBlockingQueue!T;
        this.sendq = new NonBlockingQueue!(SudoFiber!T);
        this.recvq = new NonBlockingQueue!(SudoFiber!T);
    }

    public ~this ()
    {
        this.queue.close();
        this.sendq.close();
        this.recvq.close();
    }

    public @property bool isClosed ()
    {
        return this.queue.isClosed;
    }

    public bool send (T elem)
    {
        if (isClosed())
            return false;

        Fiber fiber = Fiber.getThis();
        if (fiber is null)
        {
            this.queue.enqueue(elem);
            return true;
        }

        SudoFiber!T sf;
        if (this.recvq.tryDequeue(sf))
        {
            send_ (sf, elem);
            return true;
        }

        SudoFiber!T new_sf;
        new_sf.fiber = fiber;
        new_sf.elem_ptr = null;
        new_sf.elem = elem;

        this.sendq.enqueue(new_sf);

        fiber.yield();

        return true;
    }

    private void send_ (SudoFiber!T sf, T elem)
    {
        *(sf.elem_ptr) = elem;
        sf.fiber.call();
    }

    public bool receive (T* elem)
    {
        if (isClosed())
            return false;

        Fiber fiber = Fiber.getThis();
        if (fiber is null)
        {
            *elem = this.queue.dequeue();
            return true;
        }

        T value;
        if (this.queue.tryDequeue(value))
        {
            *elem = value;
            return true;
        }

        SudoFiber!T sf;
        if (this.sendq.tryDequeue(sf))
        {
            recv_ (sf, elem);
            return true;
        }

        SudoFiber!T new_sf;
        new_sf.fiber = fiber;
        new_sf.elem_ptr = elem;

        this.recvq.enqueue(new_sf);
        fiber.yield();

        return true;
    }

    private void recv_ (SudoFiber!T sf, T* elem)
    {
        *(elem) = sf.elem;
        sf.fiber.call();
    }

    public void close ()
    {
        this.queue.close();

        SudoFiber!T sf;
        while (true)
        {
            if (this.recvq.tryDequeue(sf))
            {
                sf.fiber.call();
            }
            else
                break;
        }

        while (true)
        {
            if (this.sendq.tryDequeue(sf))
            {
                sf.fiber.call();
            }
            else
                break;
        }
    }
}

unittest
{
    import core.thread;

    Channel!int in_channel = new Channel!int();
    Channel!int out_channel = new Channel!int();

    new Thread({
        int x;
        in_channel.receive(&x);
        int y = x * x * x;
        out_channel.send(y);
    }).start();

    in_channel.send(3);
    int res;
    out_channel.receive(&res);
    assert(res == 27);
}

unittest
{
    import core.thread;

    Channel!string in_channel = new Channel!string();
    Channel!string out_channel = new Channel!string();

    new Thread({
        string name;
        in_channel.receive(&name);
        string greeting = "Hi " ~ name;
        out_channel.send(greeting);
    }).start();

    in_channel.send("Tom");
    string res;
    out_channel.receive(&res);
    assert(res == "Hi Tom");
}

unittest
{
    Channel!int in_channel = new Channel!int();

    int res;
    in_channel.send(3);
    in_channel.receive(&res);
    assert(res == 3);

    in_channel.send(5);
    in_channel.close();
    in_channel.receive(&res);

    import std.stdio;
    writefln("%d", res);

    //assert(res == int.init);
}

unittest
{
    import core.thread;

    Channel!int in_channel = new Channel!int();
    Channel!int out_channel = new Channel!int();

    new Thread({
        int x;
        in_channel.receive(&x);
        int y = x * x * x;
        out_channel.send(y);
    }).start();

    in_channel.send(3);
    int res;
    out_channel.receive(&res);
    assert(res == 27);
}

unittest
{
    import core.thread;
    import std.stdio;

    Channel!int in_channel = new Channel!int();
    Channel!int out_channel = new Channel!int();

    void sender() {
        foreach (int idx; 1..10)
        {
            in_channel.send(idx);
            Fiber.yield();
        }
    }

    void receiver() {
        int x = 1;
        while (true)
        {
            int res;
            in_channel.receive(&res);
            assert(res == x++);
            Fiber.yield();
        }
    }

    auto f1 = new Fiber(&sender);
    auto f2 = new Fiber(&receiver);

    f1.call();
    f2.call();

    f2.call();
    f1.call();
}
