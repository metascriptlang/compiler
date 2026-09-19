// GUARD-JS

class K {
	static a: int32 = 1;
	static b: int32 = this.a + 10;
	x: int32 = 5;
	static { this.a = this.a + 1; }
	static bump(): int32 { this.a = this.a + 1; return this.a; }
	static twice(): int32 { this.bump(); return this.bump(); }
	static viaClosure(n: int32): int32 {
		const f = (m: int32): int32 => this.a + m;
		return f(n);
	}
	static make(): K { return new this(); }
}

class Sub extends K {}

function localBump(): int32 {
	class L {
		static a: int32 = 3;
		static bump(): int32 { this.a = this.a + 1; return this.a; }
	}
	return L.bump();
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
	rc += expect(K.b, 11, "staticInitializerReadsThis");
	rc += expect(K.a, 2, "staticBlockWritesThis");
	rc += expect(K.twice(), 4, "staticMethodCallsThroughThis");
	rc += expect(K.viaClosure(10), 14, "closureInStaticMethodReadsThis");
	rc += expect(K.make().x, 5, "newThisInStaticMethod");
	rc += expect(localBump(), 4, "localClassStaticMethodThis");
	rc += expect(Sub.bump(), 5, "inheritedStaticMethodThisIsDeclaringClass");
	rc += expect(K.a, 5, "inheritedStaticMethodWritesDeclaringClass");
	if (rc == 0) { console.log("GUARD-OK staticThis"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
