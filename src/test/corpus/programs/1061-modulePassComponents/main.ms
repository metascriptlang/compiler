// @stdout: count=4 badge|count=4 badge|register counter.ms:Counter,register counter.ms:Badge,render App,render Counter,render Badge,render App,render Counter,render Badge
// note: a module pass named by build.ms (`globalImports: [{ from, modulePass }]`) receives every module's statement list before declarations are collected and returns the replacement. This one is shaped like a component-refresh transform: each top-level function whose name is capitalised keeps its name and export, gets a body that first calls a new top-level function, and gains a registration statement appended to the module, which runs once per module evaluation however often the component runs (two `App()` calls, one `register` each). `Counter` is rewritten in `counter.ms` and consumed from `main.ms`, so the rewritten export is what the importer checks against. `util.ms` holds no component and must pass through unchanged; `refresh.ms` declares the pass and is never transformed. `expansionFile()` keys each registration by the module that was transformed. Parity C↔JS: the pass runs once in the compile-time VM.

import { Counter, badge } from "./counter";
import { double } from "./util";

function App(): string {
	return Counter(double(2)) + " " + badge();
}

const first = App();
const second = App();
console.log(first + "|" + second + "|" + refreshLog());
