// @stdout: cell:a x=1 cell:c dyn:zzz
// note: an extension and a getDynamicField declared on a union are reached by a receiver of that union and never by a variant narrowed out of it, which has its own fields and is not the union.
import { Cell, describe, getDynamicField } from "./a";

function show(c: Cell): string {
	if (c.kind === "a") return `x=${c.x}`;
	return "";
}

function named(c: Cell): string { return c.describe(); }
function dynamic(c: Cell): string { return c.zzz; }

const first: Cell = { kind: "a", x: 1 };
const last: Cell = { kind: "c" };
console.log(`${named(first)} ${show(first)} ${named(last)} ${dynamic(last)}`);
