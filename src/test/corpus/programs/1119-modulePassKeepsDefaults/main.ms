// @stdout: hi Ann|yo Bob|7 9 12|<none> [x>
// note: a module pass receives every module and returns it; the functions come back through the compile-time VM's node conversion, which must carry each parameter's default. Here the pass returns the module untouched, so any lost default shows as a call that no longer has its omitted arguments: a local function, an exported function with two defaulted int32 parameters called from another module with zero, one and both given, and a constructor and a method with defaults.

import { scaled, Label } from "./lib";

function greet(name: string, greeting: string = "hi"): string {
	return greeting + " " + name;
}

const a = new Label();
const b = new Label("x");
console.log(greet("Ann") + "|" + greet("Bob", "yo") + "|" + scaled(2).toString() + " " + scaled(2, 4).toString() + " " + scaled(2, 4, 4).toString() + "|" + a.show() + " " + b.show("["));
