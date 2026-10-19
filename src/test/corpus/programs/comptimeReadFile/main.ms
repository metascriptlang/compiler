// @stdout: macro hello from a file|missing caught|comptime 18
// note: std/meta readFile runs inside the compile-time VM on every target, so a macro that reads a file builds for JS as it does for C; a failed read throws to the macro's catch.

import { Node, expansionFile, readFile } from "std/meta";

function besideThis(name: string): string {
	const self = expansionFile();
	return self.substring(0, self.lastIndexOf("/") + 1) + name;
}

macro greeting(): Node {
	const text = readFile(besideThis("greeting.txt"));
	if (text == "hello from a file\n") { return quote { "macro hello from a file" }; }
	return quote { "macro read something else" };
}

macro missing(): Node {
	let text = "unread";
	try { text = readFile(besideThis("absent.txt")); } catch (e) { text = "caught"; }
	if (text == "caught") { return quote { "missing caught" }; }
	return quote { "missing not caught" };
}

const length = @comptime { return readFile(besideThis("greeting.txt")).length; };
console.log(`${greeting()}|${missing()}|comptime ${length}`);
