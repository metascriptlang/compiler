// @stdout: other 2 1|main 0 7|other-wrapped 3 2|main-wrapped 9 1
// note: two modules each declare a private `struct PagesKey` with a different layout. An
// anonymous struct holding one (a `Result` arm, or a user generic's `{ held: T }`) is a
// different C struct in each instance: C used to key the anonymous struct by the
// spelling `PagesKey`, so the second module wrote its value into the first module's layout.
import { otherParsed, otherWrapped } from "./other";
import { wrap } from "./wrap";

struct PagesKey { selectedIndex: int32; flag: boolean; items: string[]; }

function mainParsed(): string {
	const r = JSON.parse<PagesKey>(`{"items":[],"selectedIndex":7,"flag":true}`);
	return r.ok ? `${r.value.items.length} ${r.value.selectedIndex}` : "err";
}

function mainWrapped(): string {
	const w = wrap<PagesKey>({ selectedIndex: 9, flag: false, items: ["q"] });
	return `${w.held.selectedIndex} ${w.held.items.length}`;
}

console.log([`other ${otherParsed()}`, `main ${mainParsed()}`, `other-wrapped ${otherWrapped()}`, `main-wrapped ${mainWrapped()}`].join("|"));
