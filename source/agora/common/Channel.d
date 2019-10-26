module agora.common.Channel;

/*******************************************************************************

    This file contains the implementation of channels.

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/

import agora.common.Queue;

import core.thread;

///
private struct SudoFiber (T)
{
    public Fiber fiber;
    public T* elem_ptr;
    public T  elem;
}

/*******************************************************************************

    A channel is a communication class using which fiber can communicate
    with each other.
    Technically, a channel is a data transfer pipe where data can be passed
    into or read from.
    Hence one fiber can send data into a channel, while other fiber can read
    that data from the same channel

*******************************************************************************/

public class Channel (T)
{
    ///
    private size_t qsize;
    ///
    private NonBlockingQueue!T queue;

    /// collection of send waiters
    private NonBlockingQueue!(SudoFiber!(T)) sendq;

    /// collection of recv waiters
    private NonBlockingQueue!(SudoFiber!(T)) recvq;

    /// Ctor
    public this (size_t qsize = 0)
    {
        this.qsize = qsize;
        this.queue = new NonBlockingQueue!T;
        this.sendq = new NonBlockingQueue!(SudoFiber!T);
        this.recvq = new NonBlockingQueue!(SudoFiber!T);
    }

    ///
    public ~this ()
    {
        this.queue.close();
        this.sendq.close();
        this.recvq.close();
    }

    /***************************************************************************

        Send data `elem`.
        First, check the fiber that is waiting for reception.
        If there are no targets there, add fiber and data to the sending queue.

        Return:
            true if the sending is successful, otherwise false

    ***************************************************************************/

    public bool send (T elem)
    {
        if (isClosed())
            return false;

        Fiber fiber = Fiber.getThis();
        if (fiber is null)
        {
            bool res;
            bool is_waiting = true;

            new Fiber({
                res = this.send(elem);
                is_waiting = false;
            }).call();

            while (is_waiting)
                Thread.sleep(dur!("msecs")(1));
            return res;
        }

        SudoFiber!T sf;
        if (this.recvq.tryDequeue(sf))
        {
            *(sf.elem_ptr) = elem;
            if (sf.fiber !is null)
                sf.fiber.call();
            return true;
        }

        if (this.queue.count < this.qsize)
        {
            this.queue.enqueue(elem);
            return true;
        }

        SudoFiber!T new_sf;
        new_sf.fiber = fiber;
        new_sf.elem_ptr = null;
        new_sf.elem = elem;

        this.sendq.enqueue(new_sf);
        Fiber.yield();
        return true;
    }

    /***************************************************************************

        Write the data received in `elem`

        Return:
            true if the receiving is successful, otherwise false

    ***************************************************************************/

    public bool receive (T* elem)
    {
        if (isClosed())
        {
            (*elem) = T.init;
            return false;
        }

        Fiber fiber = Fiber.getThis();
        if (fiber is null)
        {
            bool res;
            bool is_waiting = true;

            new Fiber({
                res = this.receive(elem);
                is_waiting = false;
            }).call();

            while (is_waiting)
                Thread.sleep(dur!("msecs")(1));
            return res;
        }

        SudoFiber!T sf;
        if (this.sendq.tryDequeue(sf))
        {
            *(elem) = sf.elem;
            if (sf.fiber !is null)
                sf.fiber.call();
            return true;
        }

        T val;
        if (this.queue.tryDequeue(val))
        {
            *(elem) = val;
            return true;
        }

        SudoFiber!T new_sf;
        new_sf.fiber = fiber;
        new_sf.elem_ptr = elem;
        this.recvq.enqueue(new_sf);
        Fiber.yield();
        return true;
    }

    /***************************************************************************

        Return closing status

        Return:
            true if channel is closed, otherwise false

    ***************************************************************************/

    public @property bool isClosed ()
    {
        return this.queue.isClosed;
    }

    /***************************************************************************

        Close channel

    ***************************************************************************/

    public void close ()
    {
        this.queue.close();

        SudoFiber!T sf;
        while (true)
        {
            if (this.recvq.tryDequeue(sf))
                sf.fiber.call();
            else
                break;
        }

        while (true)
        {
            if (this.sendq.tryDequeue(sf))
                sf.fiber.call();
            else
                break;
        }
    }
}

unittest
{
    Channel!int channel = new Channel!int(10);

    foreach (int idx; 0 .. 10)
        channel.send(idx);

    int res;
    int expect = 0;
    foreach (int idx; 0 .. 10)
    {
        channel.receive(&res);
        assert(res == expect++);
    }
}

// multi-thread data type is int
unittest
{
    Channel!int in_channel = new Channel!int(5);
    Channel!int out_channel = new Channel!int(5);

    new Thread({
        int x;
        in_channel.receive(&x);
        out_channel.send(x * x * x);
    }).start();

    in_channel.send(3);
    int res;
    out_channel.receive(&res);
    assert(res == 27);
}

// multi-thread data type is string
unittest
{
    Channel!string in_channel = new Channel!string(5);
    Channel!string out_channel = new Channel!string(5);

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

//
unittest
{
    Channel!int channel = new Channel!int(5);

    int res;
    channel.send(1);
    assert(channel.receive(&res));

    channel.send(3);
    channel.close();
    assert(!channel.receive(&res));
}

// multi fiber, single thread data type is int
unittest
{
    Channel!int in_channel = new Channel!int(5);
    Channel!int out_channel = new Channel!int(5);

    auto fiber1 = new Fiber(
    {
        int res;
        while (true)
        {
            in_channel.receive(&res);
            out_channel.send(res*res);
        }
    });
    fiber1.call();

    auto fiber2 = new Fiber(
    {
        int res;
        foreach (int idx; 1 .. 10)
        {
            in_channel.send(idx);
            out_channel.receive(&res);
            assert(res == idx*idx);
        }
    });
    fiber2.call();
}

//
unittest
{
    Channel!int channel = new Channel!int(5);

    auto fiber = new Fiber(
    {
        int res;
        int expect = 1;
        while (true)
        {
            channel.receive(&res);
            assert(res == expect++);
        }
    });
    fiber.call();

    auto thread = new Thread(
    {
        foreach (int idx; 1 .. 10)
            channel.send(idx);
        channel.close();
    });
    thread.start();
}

//
unittest
{
    Channel!int channel = new Channel!int(5);

    auto fiber = new Fiber(
    {
        foreach (int idx; 1 .. 10)
        {
            channel.send(idx);
        }
        channel.close();
    });
    fiber.call();

    auto thread = new Thread(
    {
        int expect = 1;
        while (true)
        {
            int res;
            channel.receive(&res);
            assert(res == expect++);
        }
    });
    thread.start();
}
