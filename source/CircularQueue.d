module CircularQueue;

/*******************************************************************************

    Non-blocking multi-producer multi-QueueItemumer queue

    Copyright:
        Copyright (c) 2019 BOS Platform Foundation Korea
        All rights reserved.

    License:
        MIT License. See LICENSE for details.

*******************************************************************************/
import core.atomic;

private static class QueueItem(T)
{
    public QueueItem!T next;
    public T value;
}

/// Ditto
public class CircularQueue(T)
{
    private shared(QueueItem!T) head;
    private shared(QueueItem!T) tail;

    /// Ctor
    public this ()
    {
        shared n = new QueueItem!T();
        this.head = this.tail = n;
    }

    /// Add an element in the queue
    public void enqueue (T t)
    {
        shared item = new QueueItem!T();
        item.value = t;

        while (true)
        {
            auto last = this.tail;
            auto cur = last.next;

            if (cur !is null)
            {
                cas(&this.tail, last, cur);
                continue;
            }

            shared(QueueItem!T) dummy = null;
            if (cas(&last.next, dummy, item))
                break;
        }
    }

    /// Get an element from the queue
    public T dequeue ()
    {
        T e = void;
        while (!tryDequeue(e)) { }
        return e;
    }

    /***************************************************************************

        Deserialization support

        Params:
            element = A element of queue

        Returns:
            true if the element exist else false

    ***************************************************************************/

    public bool tryDequeue (out T element)
    {
        auto dummy = this.head;
        auto last = this.tail;
        auto next = dummy.next;

        if (dummy is last)
        {
            if (next is null)
                return false;
            else
                cas(&this.tail, last, next);
        }
        else
        {
            if (cas(&this.head, dummy, next))
            {
                element = next.value;
                return true;
            }
        }

        return false;
    }
}

/***
  Start `writers` amount of threads to write into a queue.
  Start `readers` amount of threads to read from the queue.
  Each writer counts from 0 to `count` and sends each number into the queue.
  The sum is checked at the end.
*/
void test_run(alias Q)(uint writers, uint readers, uint count)
{
    import std.range;
    import core.thread;
    import core.sync.barrier : Barrier;
    import std.bigint : BigInt;
    //import fluent.asserts;
    /* compute desired sum via Gauss formula */
    BigInt correct_sum = BigInt(count) * BigInt(count-1) / 2 * writers;
    /* compute sum via multiple threads and one queue */
    BigInt sum = 0;
    auto b = new Barrier(writers + readers);
    auto q = new Q();
    auto w = new Thread({
            Thread[] ts;
            foreach(i; 0 .. writers) {
                auto t = new Thread({
                        b.wait();
                        foreach(n; 1 .. count) {
                            q.enqueue(n);
                        }
                        });
                t.start();
                ts ~= t;
            }
            foreach(t; ts) { t.join(); }
            });
    auto r = new Thread({
            Thread[] ts;
            foreach(i; 0 .. writers) {
                auto t = new Thread({
                        BigInt s = 0;
                        b.wait();
                        foreach(_; 1 .. count) {
                            auto n = q.dequeue();
                            s += n;
                        }
                        synchronized { sum += s; }
                        });
                t.start();
                ts ~= t;
            }
            foreach(t; ts) { t.join(); }
            });
    w.start();
    r.start();
    w.join();
    r.join();
    //sum.should.equal(correct_sum);


    import std.stdio;
    writeln(sum);
    writeln(correct_sum);
}

unittest {
    import std.datetime.stopwatch : benchmark;
    enum readers = 10;
    enum writers = 10;
    enum bnd = 10; // size for bounded queues
    enum count = 10000; // too small, so only functional test
    void f0() { test_run!(CircularQueue!long)               (writers,readers,count); }
    auto r = benchmark!(f0)(3);
    import std.stdio;
    writeln(r[0]);
}
