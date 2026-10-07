// @xfail(raiser): the Raiser runs a function's static const initializer on every call (inbox 2026-10-08-raiser-static-const-runs-per-call)
// @stdout: keeps-modules static=1,1 builds=1 meters=3 deref=9,9
// note: a module pass that returns every module it is given must leave the program exactly as written. Each module crosses the macro wire whole, so every fact the parser keeps as a node flag has to survive the round trip, and each line here reads one of them back through its ordinary consumer: `static const` keeps module-scope storage (one initializer run for two calls), the `converter` declared in `units.ms` still lowers the JSX literal into a `Meters`, and `p[]` still writes through to the pointee. The same program without build.ms prints the same line. Parity C↔JS: the pass runs once in the compile-time VM.

import { Meters, toMeters } from "./units";

let builds: int32 = 0;

function mk(): int32 {
	builds = builds + 1;
	return builds;
}

function once(): int32 {
	static const t = mk();
	return t;
}

struct Cell { v: int32; }

const a = once();
const b = once();
const m: Meters = <meters/>;
let cells: Cell[1] = [{ v: 1 }];
const p = cells[0] as Ptr<Cell>;
p[].v = 9;
console.log("keeps-modules static=" + a.toString() + "," + b.toString() + " builds=" + builds.toString()
	+ " meters=" + m.v.toString() + " deref=" + p[].v.toString() + "," + cells[0].v.toString());
