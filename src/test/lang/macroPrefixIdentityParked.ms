// Parked at inbox card 2026-09-27-static-macro-prefix-rebuilds-after-first-call.md
import { memo } from "./macroPrefixFixture";

let builds: int32 = 0;

function build(): string { builds = builds + 1; return "T" + builds.toString(); }

function eachRow<T>(p: { each: T[]; row: (n: T) => string }): string { return p.row(p.each[0]); }

function renderTwoSites(): string {
	return eachRow({ each: [1], row: (n) => { const x = memo(); const y = memo(); return x + y; } });
}

test "macro prefix identity: generic recheck keeps two sites independent and persistent" {
	const before = builds;
	const expected = "T" + (before + 1).toString() + "T" + (before + 2).toString();
	assert renderTwoSites() == expected;
	assert renderTwoSites() == expected;
	assert builds == before + 2;
}
