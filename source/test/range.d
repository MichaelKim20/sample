module sample.test.range;

import std.range;
import std.stdio;

struct Negative(T)
if (isInputRange!T) {
    T range;

    bool empty() {
        return range.empty;
    }

    auto front() {
        return -range.front;
    }

    void popFront() {
        range.popFront();
    }

    static if (isForwardRange!T) {
        Negative save() {
            return Negative(range.save);
        }
    }
}

Negative!T negative(T)(T range) {
    return Negative!T(range);
}

struct FibonacciSeries {
    int current = 0;
    int next = 1;

    enum empty = false;

    int front() {
        return current;
    }

    void popFront() {
        auto nextNext = current + next;
        current = next;
        next = nextNext;
    }

    FibonacciSeries save() {
        return this;
    }
}

unittest
{
    FibonacciSeries fs;
	writeln(fs.take(5).negative);

    writeln(FibonacciSeries()
            .take(5)
            .negative
            //.cycle        // ← compilation ERROR
            .take(10));
}