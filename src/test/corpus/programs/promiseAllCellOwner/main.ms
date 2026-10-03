// Parity program — a Promise.all result collected in two modules (a struct, an int32 and an int64
// element type each) shares one result-cell TypeInfo per element type: the owning module defines it,
// the other module references it.
//
// @stdout: ab3/14/17 cd7/22/17
// @exit: 0

import { Tag, mkTag, mkInt, mkBig } from "./tag";
import { gather } from "./other";

async function main(): Promise<void> {
	const tags = await Promise.all([mkTag("a", 1), mkTag("b", 2)]);
	const ints = await Promise.all([mkInt(3), mkInt(4)]);
	const bigs = await Promise.all([mkBig(7), mkBig(8)]);
	console.log(tags[0].label + tags[1].label + (tags[0].n + tags[1].n).toString() + "/" + (ints[0] + ints[1]).toString() + "/" + (bigs[0] + bigs[1]).toString() + " " + (await gather()));
}
await main();
