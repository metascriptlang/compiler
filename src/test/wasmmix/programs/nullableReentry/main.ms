// @stdout: 107|~|109
// @stdout: 9,~,0
// @stdout: w2|~|~
import { dec, viaCallback, name, wrap } from "./nullableReentryWasm";

function showInt(v: int32 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showText(v: string | null): string {
	if (v == null) { return "~"; }
	return v;
}

const first = viaCallback(8, (x: int32): int32 => dec(x) ?? -1);
const second = viaCallback(6, (x: int32): int32 => { dec(x); return -5; });
const third = viaCallback(6, (x: int32): int32 => { dec(0); return 9; });
console.log([showInt(first), showInt(second), showInt(third)].join("|"));
console.log(`${showInt(dec(10))},${showInt(dec(-3))},${showInt(dec(1))}`);
const w1 = wrap(1, (x: int32): int32 => { const s = name(x); return s == null ? -1 : s.length; });
const w2 = wrap(5, (x: int32): int32 => { name(x); return -1; });
const w3 = wrap(-1, (x: int32): int32 => { const s = name(x); return s == null ? -1 : s.length; });
console.log([showText(w1), showText(w2), showText(w3)].join("|"));
