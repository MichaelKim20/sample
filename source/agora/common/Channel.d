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

/*******************************************************************************

    Interface for all queues.

*******************************************************************************/

private struct SudoFiber (T)
{
    public Fiber fiber;
    public T* elem_ptr;
    public T  elem;
}

/*******************************************************************************

    Interface for all queues.

*******************************************************************************/

public class Channel (T)
{
    ///
    private NonBlockingQueue!T queue;

    /// collection of send waiters
    private NonBlockingQueue!(SudoFiber!(T)) sendq;

    /// collection of recv waiters
    private NonBlockingQueue!(SudoFiber!(T)) recvq;

    /// Ctor
    public this ()
    {
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

        Return closing status

        Return:
            true if channel is closed, otherwise false

    ***************************************************************************/

    public @property bool isClosed ()
    {
        return this.queue.isClosed;
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
            bool waiting = true;
            auto sender = new Fiber({
                res = this.send(elem);
                waiting = false;
            });
            sender.call();
            while (waiting)
                Thread.sleep(dur!("msecs")(5));
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

        SudoFiber!T new_sf;
        new_sf.fiber = fiber;
        new_sf.elem_ptr = null;
        new_sf.elem = elem;

        this.sendq.enqueue(new_sf);

        Fiber.yield();

        return true;
    }

    /***************************************************************************

        Write the data received in `elem

        Return:
            true if the receiving is successful, otherwise false

    ***************************************************************************/

    public bool receive (T* elem)
    {
        if (isClosed())
            return false;

        Fiber fiber = Fiber.getThis();
        if (fiber is null)
        {
            bool res;
            bool waiting = true;
            auto receiver = new Fiber({
                res = this.receive(elem);
                waiting = false;
            });

            receiver.call();
            while (waiting)
                Thread.sleep(dur!("msecs")(5));
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

        SudoFiber!T new_sf;
        new_sf.fiber = fiber;
        new_sf.elem_ptr = elem;

        this.recvq.enqueue(new_sf);

        Fiber.yield();

        return true;
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

// multi-thread data type is int
unittest
{
    Channel!int in_channel = new Channel!int();
    Channel!int out_channel = new Channel!int();

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

//
unittest
{
    Channel!int in_channel = new Channel!int();

    new Thread({
        in_channel.send(3);
    }).start();

    in_channel.close();
    int res;
    assert(!in_channel.receive(&res));
}

// multi fiber, single thread data type is int
unittest
{
    Channel!int in_channel = new Channel!int();
    Channel!int out_channel = new Channel!int();

    void sender ()
    {
        foreach (int idx; 0..10)
        {
            in_channel.send(idx);
            Fiber.yield();
        }
    }

    void receiver ()
    {
        int expect = 0;
        while (true)
        {
            int res;
            in_channel.receive(&res);
            assert(res == expect++);
            Fiber.yield();
        }
    }

    auto f1 = new Fiber(&sender);
    auto f2 = new Fiber(&receiver);

    foreach (i; 0..5)
    {
        f1.call();
        f2.call();

        f2.call();
        f1.call();
    }
}

//
unittest
{
    Channel!int in_channel = new Channel!int();

    auto fiber = new Fiber(
    {
        int expect = 1;
        while (true)
        {
            int res;
            in_channel.receive(&res);
            assert(res == expect++);
        }
    });
    fiber.call();

    auto thread = new Thread(
    {
        foreach (int idx; 1 .. 10)
        {
            in_channel.send(idx);
        }
        in_channel.close();
    });
    thread.start();
}

unittest
{
    Channel!int in_channel = new Channel!int();

    auto fiber = new Fiber(
    {
        foreach (int idx; 1 .. 10)
        {
            in_channel.send(idx);
        }
        in_channel.close();
    });
    fiber.call();

    auto thread = new Thread(
    {
        int expect = 1;
        while (true)
        {
            int res;
            in_channel.receive(&res);
            assert(res == expect++);
        }
    });
    thread.start();
}
