// GUARD-JS
// GUARD-CHECK-FAIL property 's' is used before its initialization
// A static block runs in class-body order, so a static field initialized
// further down the body has not been set yet when the block runs.

class K {
	static { K.s = "from-block"; }
	static s: string = "literal";
}

function main(): int32 { return K.s == "literal" ? 0 : 1; }
const rc = main();
if (rc != 0) { process.exit(rc); }
