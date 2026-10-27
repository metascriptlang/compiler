// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: add x
// @stdout: log a b
// @stdout: total 3
// @stdout: destroy order y g
//
// The methods, constructor and onDestroy of an exported class release what they replace,
// whether the class is used in its own module or imported, and whether the object dies
// in a function or with the module that holds it.

import { Logger, Tracker } from "./tracker";
import { held } from "./holder";

function local(): void {
	const t = new Tracker("y");
	t.rename("y");
}

const l = new Logger();
l.add("x");
console.log(`add${l.text}`);
l.reset();
l.add("a");
l.add("b");
console.log(`log${l.text}`);
console.log(`total ${l.count + held.name.length}`);
local();
