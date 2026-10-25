// A nonisolated read is pin, copy, unpin: each value type comes back as an independent value,
// two actors read in one expression keep their own pins, and a spawn thread reads while the actor lives.
// RED MEANS: a read returns the wrong field, shares a string payload, or leaks its pin.
//
// GUARD-JS
// GUARD-TSAN

import { nonisolated } from "std/actor";

enum Color { Red, Green }

actor Srv {
	@nonisolated
	readonly count: int32 = 7;
	@nonisolated
	readonly ratio: float64 = 2.5;
	@nonisolated
	readonly flag: boolean = true;
	@nonisolated
	readonly color: Color = Color.Green;
	@nonisolated
	readonly big: bigint = 12345678901234567890n;
	@nonisolated
	readonly name: string = "s".repeat(300);
	ping(): int32 { return 1; }
}

actor Other {
	@nonisolated
	readonly name: string = "other";
	ping(): int32 { return 2; }
}

function expect(ok: boolean, what: string): int32 {
	if (ok) return 0;
	console.log("GUARD-FAIL " + what);
	return 1;
}

async function main(): Promise<int32> {
	const a = new Srv();
	const b = new Other();
	await a.ping();
	await b.ping();
	let rc: int32 = 0;
	rc += expect(a.count == 7, "int32");
	rc += expect(a.ratio == 2.5, "float64");
	rc += expect(a.flag, "boolean");
	rc += expect(a.color == Color.Green, "enum");
	rc += expect(a.big == 12345678901234567890n, "bigint");
	rc += expect(a.name.length == 300, "string");
	rc += expect(a.name + b.name == "s".repeat(300) + "other", "two actors in one expression");
	rc += expect(a.count > 0 && b.name.length == 5, "short-circuit reads both operands");
	rc += expect(!(a.count > 100 && b.name.length == 5), "short-circuit stops at the left operand");
	rc += expect((a.flag ? b.name : a.name).length == 5, "ternary arm");
	const t = spawn((): int64 => {
		let total: int64 = 0;
		for (let i = 0; i < 1000; i = i + 1) {
			const v = a.name;
			total = total + v.length;
		}
		return total;
	});
	rc += expect(await t == 300000, "spawn reader");
	return rc;
}

const rc = await main();
if (rc != 0) process.exit(rc);
console.log("GUARD-OK");
