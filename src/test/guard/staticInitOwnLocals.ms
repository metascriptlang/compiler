// GUARD-JS

let base: int32 = 4;

function local(): int32 {
	class L {
		static a: int32 = 0;
		static f: (x: int32) => int32 = (x: int32): int32 => x + base;
		static {
			const t: int32 = base + 1;
			for (const x of [1, 2]) { L.a = L.a + t + x; }
		}
	}
	return L.a + L.f(1);
}

class M {
	static b: int32 = 0;
	static { let u: int32 = 3; M.b = u; }
}

function expect(actual: int32, want: int32, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

function main(): int32 {
	let rc: int32 = 0;
	rc += expect(local(), 18, "localClassStaticOwnLocals");
	rc += expect(M.b, 3, "moduleClassStaticBlockLocal");
	if (rc == 0) { console.log("GUARD-OK staticInitOwnLocals"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
