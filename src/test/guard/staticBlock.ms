// GUARD-JS
// A `static { }` block (TS ES2022) runs at module init, in class-body order
// with the computed static field initializers around it, and may assign the
// class's own `static readonly` fields.
//
// A red guard means the static run-part drifted out of the statement stream.

let trace: string = "";
function mark(s: string): int32 { trace = trace + s + ","; return 1; }

class K {
	static a: int32 = mark("a");
	static b: int32 = 0;
	static { mark("block1"); K.b = K.a + 1; }
	static c: int32 = mark("c");
	static { mark("block2"); }
	static readonly frozen: int32 = 0;
	static { K.frozen = 7; }
}

function expect(actual: string, want: string, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

function main(): int32 {
	let rc: int32 = 0;
	rc += expect(trace, "a,block1,c,block2,", "staticBodyOrder");
	rc += expect(`${K.b}`, "2", "blockSeesEarlierField");
	rc += expect(`${K.frozen}`, "7", "ownStaticReadonlyWritable");
	if (rc == 0) { console.log("GUARD-OK staticBlock"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
