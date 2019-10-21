module agora.common.Channel;

import agora.common.Queue;

import std.conv;

import core.thread;

version (unittest)
private struct SquareResult
{
    private int input;
    private int output;

    public this (int input, int output)
    {
        this.input = input;
        this.output = output;
    }

    public string toString ()
    {
        return to!string(input) ~ "^2 = " ~ to!string(output);
    }
}

version (unittest)
private class Squarer
{
    private NonBlockingQueue!int qi;
    private NonBlockingQueue!SquareResult qo;

    public this (NonBlockingQueue!int qi, NonBlockingQueue!SquareResult qo)
    {
        this.qi = qi;
        this.qo = qo;
    }

    public void start ()
    {
        new Thread(
            {
                int x = this.qi.dequeue();
                int y = x * x;
                this.qo.enqueue(SquareResult(x, y));
            }
        ).start();
    }
}

unittest
{
    import std.stdio;
    NonBlockingQueue!int request = new NonBlockingQueue!int();
    NonBlockingQueue!SquareResult response = new NonBlockingQueue!SquareResult();

    Squarer squarer = new Squarer(request, response);
    squarer.start();

    try {
        request.enqueue(42);
        assert(response.dequeue().toString == "42^2 = 1764");
    } catch (Exception ie) {
    }
}


public import std.variant;

import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import std.range.primitives;
import std.range.interfaces : InputRange;
import std.traits;

public enum MsgType
{
    standard,
    priority,
    linkDead,
}

public struct Message
{
    MsgType type;
    Variant data;

    this(T...)(MsgType t, T vals) if (T.length > 0)
    {
        static if (T.length == 1)
        {
            type = t;
            data = vals[0];
        }
        else
        {
            import std.typecons : Tuple;

            type = t;
            data = Tuple!(T)(vals);
        }
    }

    @property auto convertsTo(T...)()
    {
        static if (T.length == 1)
        {
            return is(T[0] == Variant) || data.convertsTo!(T);
        }
        else
        {
            import std.typecons : Tuple;
            return data.convertsTo!(Tuple!(T));
        }
    }

    @property auto get(T...)()
    {
        static if (T.length == 1)
        {
            static if (is(T[0] == Variant))
                return data;
            else
                return data.get!(T);
        }
        else
        {
            import std.typecons : Tuple;
            return data.get!(Tuple!(T));
        }
    }

    auto map(Op)(Op op)
    {
        alias Args = Parameters!(Op);

        static if (Args.length == 1)
        {
            static if (is(Args[0] == Variant))
                return op(data);
            else
                return op(data.get!(Args));
        }
        else
        {
            import std.typecons : Tuple;
            return op(data.get!(Tuple!(Args)).expand);
        }
    }
}

/*
* A MessageBox is a message queue for one thread.  Other threads may send
* messages to this owner by calling put(), and the owner receives them by
* calling get().  The put() call is therefore effectively shared and the
* get() call is effectively local.  setMaxMsgs may be used by any thread
* to limit the size of the message queue.
*/
class MessageBox
{
    this() @trusted nothrow /* TODO: make @safe after relevant druntime PR gets merged */
    {
        m_lock = new Mutex;
        m_closed = false;

        //if (scheduler is null)
        //{
            m_putMsg = new Condition(m_lock);
            m_notFull = new Condition(m_lock);
       // }
        //else
        //{
         //   m_putMsg = scheduler.newCondition(m_lock);
         //   m_notFull = scheduler.newCondition(m_lock);
        //}
    }

    ///
    final @property bool isClosed() @safe @nogc pure
    {
        synchronized (m_lock)
        {
            return m_closed;
        }
    }

    /*
    * Sets a limit on the maximum number of user messages allowed in the
    * mailbox.  If this limit is reached, the caller attempting to add
    * a new message will execute call.  If num is zero, there is no limit
    * on the message queue.
    *
    * Params:
    *  num  = The maximum size of the queue or zero if the queue is
    *         unbounded.
    *  call = The routine to call when the queue is full.
    */
    final void setMaxMsgs(size_t num, bool function(Tid) call) @safe @nogc pure
    {
        synchronized (m_lock)
        {
            m_maxMsgs = num;
            m_onMaxMsgs = call;
        }
    }

    /*
    * If maxMsgs is not set, the message is added to the queue and the
    * owner is notified.  If the queue is full, the message will still be
    * accepted if it is a control message, otherwise onCrowdingDoThis is
    * called.  If the routine returns true, this call will block until
    * the owner has made space available in the queue.  If it returns
    * false, this call will abort.
    *
    * Params:
    *  msg = The message to put in the queue.
    *
    * Throws:
    *  An exception if the queue is full and onCrowdingDoThis throws.
    */
    final void put(ref Message msg)
    {
        synchronized (m_lock)
        {
            // TODO: Generate an error here if m_closed is true, or maybe
            //       put a message in the caller's queue?
            if (!m_closed)
            {
                while (true)
                {
                    if (isPriorityMsg(msg))
                    {
                        m_sharedPty.put(msg);
                        m_putMsg.notify();
                        return;
                    }
                    if (!mboxFull() || isControlMsg(msg))
                    {
                        m_sharedBox.put(msg);
                        m_putMsg.notify();
                        return;
                    }
                    if (m_onMaxMsgs !is null && !m_onMaxMsgs(thisTid))
                    {
                        return;
                    }
                    m_putQueue++;
                    m_notFull.wait();
                    m_putQueue--;
                }
            }
        }
    }

    /*
    * Matches ops against each message in turn until a match is found.
    *
    * Params:
    *  ops = The operations to match.  Each may return a bool to indicate
    *        whether a message with a matching type is truly a match.
    *
    * Returns:
    *  true if a message was retrieved and false if not (such as if a
    *  timeout occurred).
    *
    * Throws:
    *  LinkTerminated if a linked thread terminated, or OwnerTerminated
    * if the owner thread terminates and no existing messages match the
    * supplied ops.
    */
    bool get(T...)(scope T vals)
    {
        import std.meta : AliasSeq;

        static assert(T.length, "T must not be empty");

        static if (isImplicitlyConvertible!(T[0], Duration))
        {
            alias Ops = AliasSeq!(T[1 .. $]);
            alias ops = vals[1 .. $];
            enum timedWait = true;
            Duration period = vals[0];
        }
        else
        {
            alias Ops = AliasSeq!(T);
            alias ops = vals[0 .. $];
            enum timedWait = false;
        }

        bool onStandardMsg(ref Message msg)
        {
            foreach (i, t; Ops)
            {
                alias Args = Parameters!(t);
                auto op = ops[i];

                if (msg.convertsTo!(Args))
                {
                    static if (is(ReturnType!(t) == bool))
                    {
                        return msg.map(op);
                    }
                    else
                    {
                        msg.map(op);
                        return true;
                    }
                }
            }
            return false;
        }

        bool onLinkDeadMsg(ref Message msg)
        {
            assert(msg.convertsTo!(Tid),
                    "Message could be converted to Tid");
            auto tid = msg.get!(Tid);

            if (bool* pDepends = tid in thisInfo.links)
            {
                auto depends = *pDepends;
                thisInfo.links.remove(tid);
                // Give the owner relationship precedence.
                if (depends && tid != thisInfo.owner)
                {
                    auto e = new LinkTerminated(tid);
                    auto m = Message(MsgType.standard, e);
                    if (onStandardMsg(m))
                        return true;
                    throw e;
                }
            }
            if (tid == thisInfo.owner)
            {
                thisInfo.owner = Tid.init;
                auto e = new OwnerTerminated(tid);
                auto m = Message(MsgType.standard, e);
                if (onStandardMsg(m))
                    return true;
                throw e;
            }
            return false;
        }

        bool onControlMsg(ref Message msg)
        {
            switch (msg.type)
            {
            case MsgType.linkDead:
                return onLinkDeadMsg(msg);
            default:
                return false;
            }
        }

        bool scan(ref ListT list)
        {
            for (auto range = list[]; !range.empty;)
            {
                // Only the message handler will throw, so if this occurs
                // we can be certain that the message was handled.
                scope (failure)
                    list.removeAt(range);

                if (isControlMsg(range.front))
                {
                    if (onControlMsg(range.front))
                    {
                        // Although the linkDead message is a control message,
                        // it can be handled by the user.  Since the linkDead
                        // message throws if not handled, if we get here then
                        // it has been handled and we can return from receive.
                        // This is a weird special case that will have to be
                        // handled in a more general way if more are added.
                        if (!isLinkDeadMsg(range.front))
                        {
                            list.removeAt(range);
                            continue;
                        }
                        list.removeAt(range);
                        return true;
                    }
                    range.popFront();
                    continue;
                }
                else
                {
                    if (onStandardMsg(range.front))
                    {
                        list.removeAt(range);
                        return true;
                    }
                    range.popFront();
                    continue;
                }
            }
            return false;
        }

        bool pty(ref ListT list)
        {
            if (!list.empty)
            {
                auto range = list[];

                if (onStandardMsg(range.front))
                {
                    list.removeAt(range);
                    return true;
                }
                if (range.front.convertsTo!(Throwable))
                    throw range.front.get!(Throwable);
                else if (range.front.convertsTo!(shared(Throwable)))
                    throw range.front.get!(shared(Throwable));
                else
                    throw new PriorityMessageException(range.front.data);
            }
            return false;
        }

        static if (timedWait)
        {
            import core.time : MonoTime;
            auto limit = MonoTime.currTime + period;
        }

        while (true)
        {
            ListT arrived;

            if (pty(m_localPty) || scan(m_localBox))
            {
                return true;
            }
            yield();
            synchronized (m_lock)
            {
                updateMsgCount();
                while (m_sharedPty.empty && m_sharedBox.empty)
                {
                    // NOTE: We're notifying all waiters here instead of just
                    //       a few because the onCrowding behavior may have
                    //       changed and we don't want to block sender threads
                    //       unnecessarily if the new behavior is not to block.
                    //       This will admittedly result in spurious wakeups
                    //       in other situations, but what can you do?
                    if (m_putQueue && !mboxFull())
                        m_notFull.notifyAll();
                    static if (timedWait)
                    {
                        if (period <= Duration.zero || !m_putMsg.wait(period))
                            return false;
                    }
                    else
                    {
                        m_putMsg.wait();
                    }
                }
                m_localPty.put(m_sharedPty);
                arrived.put(m_sharedBox);
            }

            if (m_localPty.empty)
            {
                scope (exit) m_localBox.put(arrived);
                if (scan(arrived))
                {
                    return true;
                }
                else
                {
                    static if (timedWait)
                    {
                        period = limit - MonoTime.currTime;
                    }
                    continue;
                }
            }
            m_localBox.put(arrived);
            pty(m_localPty);
            return true;
        }
    }

    /*
    * Called on thread termination.  This routine processes any remaining
    * control messages, clears out message queues, and sets a flag to
    * reject any future messages.
    */
    final void close()
    {
        static void onLinkDeadMsg(ref Message msg)
        {
            assert(msg.convertsTo!(Tid),
                    "Message could be converted to Tid");
            auto tid = msg.get!(Tid);

            thisInfo.links.remove(tid);
            if (tid == thisInfo.owner)
                thisInfo.owner = Tid.init;
        }

        static void sweep(ref ListT list)
        {
            for (auto range = list[]; !range.empty; range.popFront())
            {
                if (range.front.type == MsgType.linkDead)
                    onLinkDeadMsg(range.front);
            }
        }

        ListT arrived;

        sweep(m_localBox);
        synchronized (m_lock)
        {
            arrived.put(m_sharedBox);
            m_closed = true;
        }
        m_localBox.clear();
        sweep(arrived);
    }

private:
    // Routines involving local data only, no lock needed.

    bool mboxFull() @safe @nogc pure nothrow
    {
        return m_maxMsgs && m_maxMsgs <= m_localMsgs + m_sharedBox.length;
    }

    void updateMsgCount() @safe @nogc pure nothrow
    {
        m_localMsgs = m_localBox.length;
    }

    bool isControlMsg(ref Message msg) @safe @nogc pure nothrow
    {
        return msg.type != MsgType.standard && msg.type != MsgType.priority;
    }

    bool isPriorityMsg(ref Message msg) @safe @nogc pure nothrow
    {
        return msg.type == MsgType.priority;
    }

    bool isLinkDeadMsg(ref Message msg) @safe @nogc pure nothrow
    {
        return msg.type == MsgType.linkDead;
    }

    alias OnMaxFn = bool function(Tid);
    alias ListT = List!(Message);

    ListT m_localBox;
    ListT m_localPty;

    Mutex m_lock;
    Condition m_putMsg;
    Condition m_notFull;
    size_t m_putQueue;
    ListT m_sharedBox;
    ListT m_sharedPty;
    OnMaxFn m_onMaxMsgs;
    size_t m_localMsgs;
    size_t m_maxMsgs;
    bool m_closed;
}

/*
*
*/
struct List(T)
{
    struct Range
    {
        import std.exception : enforce;

        @property bool empty() const
        {
            return !m_prev.next;
        }

        @property ref T front()
        {
            enforce(m_prev.next, "invalid list node");
            return m_prev.next.val;
        }

        @property void front(T val)
        {
            enforce(m_prev.next, "invalid list node");
            m_prev.next.val = val;
        }

        void popFront()
        {
            enforce(m_prev.next, "invalid list node");
            m_prev = m_prev.next;
        }

        private this(Node* p)
        {
            m_prev = p;
        }

        private Node* m_prev;
    }

    void put(T val)
    {
        put(newNode(val));
    }

    void put(ref List!(T) rhs)
    {
        if (!rhs.empty)
        {
            put(rhs.m_first);
            while (m_last.next !is null)
            {
                m_last = m_last.next;
                m_count++;
            }
            rhs.m_first = null;
            rhs.m_last = null;
            rhs.m_count = 0;
        }
    }

    Range opSlice()
    {
        return Range(cast(Node*)&m_first);
    }

    void removeAt(Range r)
    {
        import std.exception : enforce;

        assert(m_count, "Can not remove from empty Range");
        Node* n = r.m_prev;
        enforce(n && n.next, "attempting to remove invalid list node");

        if (m_last is m_first)
            m_last = null;
        else if (m_last is n.next)
            m_last = n; // nocoverage
        Node* to_free = n.next;
        n.next = n.next.next;
        freeNode(to_free);
        m_count--;
    }

    @property size_t length()
    {
        return m_count;
    }

    void clear()
    {
        m_first = m_last = null;
        m_count = 0;
    }

    @property bool empty()
    {
        return m_first is null;
    }

    private:
        struct Node
        {
            Node* next;
            T val;

            this(T v)
            {
                val = v;
            }
        }

        static shared struct SpinLock
        {
            void lock() { while (!cas(&locked, false, true)) { Thread.yield(); } }
            void unlock() { atomicStore!(MemoryOrder.rel)(locked, false); }
            bool locked;
        }

        static shared SpinLock sm_lock;
        static shared Node* sm_head;

        Node* newNode(T v)
        {
            Node* n;
            {
                sm_lock.lock();
                scope (exit) sm_lock.unlock();

                if (sm_head)
                {
                    n = cast(Node*) sm_head;
                    sm_head = sm_head.next;
                }
            }
            if (n)
            {
                import std.conv : emplace;
                emplace!Node(n, v);
            }
            else
            {
                n = new Node(v);
            }
            return n;
        }

        void freeNode(Node* n)
        {
            // destroy val to free any owned GC memory
            destroy(n.val);

            sm_lock.lock();
            scope (exit) sm_lock.unlock();

            auto sn = cast(shared(Node)*) n;
            sn.next = sm_head;
            sm_head = sn;
        }

        void put(Node* n)
        {
            m_count++;
            if (!empty)
            {
                m_last.next = n;
                m_last = n;
                return;
            }
            m_first = n;
            m_last = n;
        }

        Node* m_first;
        Node* m_last;
        size_t m_count;
}
/**
 * An opaque type used to represent a logical thread.
 */
struct Tid
{
private:
    this(MessageBox m) @safe pure nothrow @nogc
    {
        mbox = m;
    }

    MessageBox mbox;

public:

    /**
     * Generate a convenient string for identifying this Tid.  This is only
     * useful to see if Tid's that are currently executing are the same or
     * different, e.g. for logging and debugging.  It is potentially possible
     * that a Tid executed in the future will have the same toString() output
     * as another Tid that has already terminated.
     */
    void toString(scope void delegate(const(char)[]) sink)
    {
        import std.format : formattedWrite;
        formattedWrite(sink, "Tid(%x)", cast(void*) mbox);
    }

}

/**
 * Returns: The $(LREF Tid) of the caller's thread.
 */
@property Tid thisTid() @safe
{
    // TODO: remove when concurrency is safe
    static auto trus() @trusted
    {
        if (thisInfo.ident != Tid.init)
            return thisInfo.ident;
        thisInfo.ident = Tid(new MessageBox);
        return thisInfo.ident;
    }

    return trus();
}

@property ref ThreadInfo thisInfo() nothrow
{
    //if (scheduler is null)
        return ThreadInfo.thisInfo;
    //return scheduler.thisInfo;
}

/**
 * Encapsulates all implementation-level data needed for scheduling.
 *
 * When defining a Scheduler, an instance of this struct must be associated
 * with each logical thread.  It contains all implementation-level information
 * needed by the internal API.
 */
struct ThreadInfo
{
    Tid ident;
    bool[Tid] links;
    Tid owner;

    /**
     * Gets a thread-local instance of ThreadInfo.
     *
     * Gets a thread-local instance of ThreadInfo, which should be used as the
     * default instance when info is requested for a thread not created by the
     * Scheduler.
     */
    static @property ref thisInfo() nothrow
    {
        static ThreadInfo val;
        return val;
    }

    /**
     * Cleans up this ThreadInfo.
     *
     * This must be called when a scheduled thread terminates.  It tears down
     * the messaging system for the thread and notifies interested parties of
     * the thread's termination.
     */
    void cleanup()
    {
        if (ident.mbox !is null)
            ident.mbox.close();
        //foreach (tid; links.keys)
            //_send(MsgType.linkDead, tid, ident);
        //if (owner != Tid.init)
            //_send(MsgType.linkDead, owner, ident);
        //unregisterMe(); // clean up registry entries
    }
}
