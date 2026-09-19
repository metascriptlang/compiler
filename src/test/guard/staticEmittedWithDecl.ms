// GUARD-JS

function seven(): int32 { return 7; }
function make(): L { return new L(); }

class L {
	static a: int32 = seven();
	x: int32 = 1;
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
	rc += expect(make().x + L.a, 8, "staticOfClassUsedBeforeItsDeclaration");
	if (rc == 0) { console.log("GUARD-OK staticEmittedWithDecl"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
