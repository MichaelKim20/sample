module sample.test.enrollment;

import std.algorithm;
import std.stdio;

public static immutable uint ValidatorCycle = 1008; // freezing period / 2


void getRange (ulong last_block_height)
{
    const min_height = max(long(0), long(last_block_height) - ValidatorCycle + 1);
    const max_height = last_block_height + 1;

    writefln("%s %s %s %s", last_block_height, min_height, max_height, max_height-min_height);
}

unittest
{
    foreach (idx; 9000 .. 10000)
    {
        getRange(idx);
    }
}
