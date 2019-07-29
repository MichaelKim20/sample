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
    return 0;
}

void test01()
{
    string[]  values;

    values ~= "1";
    values ~= "2";
    values ~= "3";
    values ~= "4";

    writeln(values);
}
