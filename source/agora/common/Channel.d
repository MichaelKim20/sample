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

import core.sync.mutex;
import core.thread;

import std.container : DList;
import std.range;

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
    /// closed
    private bool closed;

    /// lock
    private Mutex mutex;

    /// size of queue
    private size_t qsize;

    /// queue of data
    private DList!T queue;

    /// collection of send waiters
    private DList!(SudoFiber!(T)) sendq;

    /// collection of recv waiters
    private DList!(SudoFiber!(T)) recvq;


    /// Ctor
    public this (size_t qsize = 0)
    {
        this.closed = false;
        this.mutex = new Mutex;
        this.qsize = qsize;
    }

    /***************************************************************************

        Send data `elem`.
        First, check the fiber that is waiting for reception.
        If there are no targets there, add fiber and data to the sending queue.

        Params:
            elem = value to send

        Return:
            true if the sending is successful, otherwise false

    ***************************************************************************/

    public bool send (T elem)
    {
        this.mutex.lock_nothrow();

        if (this.closed)
        {
            this.mutex.unlock_nothrow();
            return false;
        }

        if (this.recvq[].walkLength > 0)
        {
            SudoFiber!T sf = this.recvq.front;
            this.recvq.removeFront();

            this.mutex.unlock_nothrow();

            *(sf.elem_ptr) = elem;
            if (sf.fiber !is null)
                sf.fiber.call();
            return true;
        }

        if (this.queue[].walkLength < this.qsize)
        {
            this.queue.insertBack(elem);
            this.mutex.unlock_nothrow();
            return true;
        }

        Fiber fiber = Fiber.getThis();
        if (fiber is null)
        {
            bool is_waiting = true;
            auto f = new Fiber({
                is_waiting = false;
            });

            SudoFiber!T new_sf;
            new_sf.fiber = f;
            new_sf.elem_ptr = null;
            new_sf.elem = elem;
            this.sendq.insertBack(new_sf);

            this.mutex.unlock_nothrow();

            while (is_waiting)
                Thread.sleep(dur!("msecs")(1));

            return true;
        }

        SudoFiber!T new_sf;
        new_sf.fiber = fiber;
        new_sf.elem_ptr = null;
        new_sf.elem = elem;
        this.sendq.insertBack(new_sf);

        this.mutex.unlock_nothrow();

        Fiber.yield();

        return true;
    }

    /***************************************************************************

        Write the data received in `elem`

        Params:
            elem = value to receive

        Return:
            true if the receiving is successful, otherwise false

    ***************************************************************************/

    public bool receive (T* elem)
    {
        this.mutex.lock_nothrow();

        if (this.closed)
        {
            (*elem) = T.init;
            this.mutex.unlock_nothrow();

            return false;
        }

        if (this.sendq[].walkLength > 0)
        {
            SudoFiber!T sf = this.sendq.front;
            this.sendq.removeFront();

            this.mutex.unlock_nothrow();

            *(elem) = sf.elem;

            if (sf.fiber !is null)
                sf.fiber.call();

            return true;
        }

        if (this.queue[].walkLength > 0)
        {
            *(elem) = this.queue.front;
            this.queue.removeFront();

            this.mutex.unlock_nothrow();

            return true;
        }

        Fiber fiber = Fiber.getThis();
        if (fiber is null)
        {
            bool is_waiting = true;
            auto f = new Fiber({
                is_waiting = false;
            });

            SudoFiber!T new_sf;
            new_sf.fiber = f;
            new_sf.elem_ptr = elem;
            this.recvq.insertBack(new_sf);

            this.mutex.unlock_nothrow();

            while (is_waiting)
                Thread.sleep(dur!("msecs")(1));

            return true;
        }

        SudoFiber!T new_sf;
        new_sf.fiber = fiber;
        new_sf.elem_ptr = elem;
        this.recvq.insertBack(new_sf);

        this.mutex.unlock_nothrow();

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
        bool closed;
        synchronized (this.mutex)
        {
            closed = this.closed;
        }
        return closed;
    }

    /***************************************************************************

        Close channel

    ***************************************************************************/

    public void close ()
    {
        SudoFiber!T sf;
        bool res;

        synchronized (this.mutex)
        {
            this.closed = true;
        }

        while (true)
        {
            synchronized (this.mutex)
            {
                if (this.recvq[].walkLength > 0)
                {
                    sf = this.recvq.front;
                    this.recvq.removeFront();
                    res = true;
                }
                else
                    res = false;
            }

            if (res)
                sf.fiber.call();
            else
                break;
        }

        while (true)
        {
            synchronized (this.mutex)
            {
                if (this.sendq[].walkLength > 0)
                {
                    sf = this.sendq.front;
                    this.sendq.removeFront();
                    res = true;
                }
                else
                    res = false;
            }

            if (res)
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
