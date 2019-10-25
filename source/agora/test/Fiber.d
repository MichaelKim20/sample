module agora.test.Fiber;

import core.thread;

void fibonacciSeries(ref int current) {                 // (1)
    current = 0;    // Note that 'current' is the parameter
    int next = 1;

    while (true) {
        Fiber.yield();                                  // (2)
        /* Next call() will continue from this point */ // (3)

        const nextNext = current + next;
        current = next;
        next = nextNext;
    }
}

unittest
{
    int current;                                        // (1)
                                                        // (4)
    Fiber fiber = new Fiber(() => fibonacciSeries(current));

    foreach (_; 0 .. 10) {
        fiber.call();                                   // (5)

        import std.stdio;
        //writef("%s ", current);
    }
}
