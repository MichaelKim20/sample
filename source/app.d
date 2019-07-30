module app;
import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;
import vibe.data.json;
import std.digest.sha;

import std.stdio;

///
import geod24.bitblob;
import geod24.LocalRest;

/// An array of const characters
public alias cstring = const(char)[];

/// 256 bits hash type, binary compatible with Stellar's definition
public alias Hash = BitBlob!256;

private int main (string[] args)
{
    test01();
    test03();
    return 0;
}

void test01()
{
    string[]  values;

    values ~= "1";
    values ~= "2";
    values ~= "3";
    values ~= "4";
    test02(values);
    writeln(values);
}

void test02(ref string[] v)
{
    string[]  values = v;

    v ~= "5";
    values ~= "6";
    values ~= "7";
    values ~= "8";
}

void test03()
{

    import std.algorithm;
    import std.range;

    immutable len = 15;
    for (size_t order = 0; order < 3; order++)
    {
        immutable start = len - (len >> (order));
        immutable end   = len - (len >> (order + 1));
        writefln("%d ~ %d", start, end);
    }

    int[]  values;

    values ~= 1;
    values ~= 3;
    values ~= 8;
    values ~= 4;
    values ~= 7;
    values ~= 5;
    values ~= 6;
    values ~= 2;

    values.length = 15;
    values[0..8].chunks(2).map!(tup => tup[0] + tup[1])
    .enumerate(size_t(8))
    .each!((idx, val) => values[idx] = val);

    values[8..12].chunks(2).map!(tup => tup[0] + tup[1])
    .enumerate(size_t(12))
    .each!((idx, val) => values[idx] = val);

    values[12..14].chunks(2).map!(tup => tup[0] + tup[1])
    .enumerate(size_t(14))
    .each!((idx, val) => values[idx] = val);

    writeln(values);
}
