// @stdout: l2 a,b
// @stdout: t
// @stdout: m1 c
// @xfail(raiser): raiser runtime error: Unknown host function: msFutureThen
// note: a then callback on a promise of a struct that owns heap fields releases it through the struct's own destroy hook, whether the struct is declared in another module (passed by pointer or by value) or in this one.

import { Batch, Tag, nextBatch, nextTag } from "./batch";

struct Local { paths: string[]; label: string; count: int32; }

async function local(): Promise<Local> {
	return { paths: ["c"], label: "m", count: 1 };
}

nextBatch().then((b: Batch): void => { console.log(`${b.label}${b.count} ${b.paths.join(",")}`); });
nextTag().then((t: Tag): void => { console.log(t.label); });
local().then((b: Local): void => { console.log(`${b.label}${b.count} ${b.paths.join(",")}`); });
