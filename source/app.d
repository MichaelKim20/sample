/+ dub.sdl:
	name "test"
	description "Tests vibe.d's std.concurrency integration"
	dependency "vibe-core" path="../"
+/
module test;

import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.web.rest;

import std.concurrency;
import core.atomic;
import core.time;
import core.stdc.stdlib : exit;

void main()
{

}
