// @stdout: decorator-keeps-syntax-flags PASS
// note: a decorator that returns the class it was given must leave the program unchanged. The class crosses the macro wire and back, so every fact the parser recorded as a node flag has to cross with it: `static const` in a method lost its storage class and ran its initializer on every call (`builds` 3 after four calls, not 2). The undecorated twin pins the expected count. The decorator lives in its own module because that is how a library ships one. Parity C↔JS: the wire runs once in the compile-time VM.

import { keep } from "./keep";

let builds: int32 = 0;

function mk(): int32 {
	builds = builds + 1;
	return builds;
}

@keep
class Decorated {
	tick(): int32 {
		static const t = mk();
		return t;
	}
}

class Plain {
	tick(): int32 {
		static const t = mk();
		return t;
	}
}

let ok = true;
const d = new Decorated();
if (d.tick() != 1) ok = false;
if (d.tick() != 1) ok = false;
const p = new Plain();
if (p.tick() != 2) ok = false;
if (p.tick() != 2) ok = false;
if (builds != 2) ok = false;
console.log(ok ? "decorator-keeps-syntax-flags PASS" : `decorator-keeps-syntax-flags FAIL builds=${builds}`);
