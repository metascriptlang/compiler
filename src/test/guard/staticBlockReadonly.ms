// GUARD-JS
// GUARD-CHECK-FAIL cannot assign to 'k' because it is a read-only property
// A static block only unlocks the `static readonly` fields of the class that
// declares it — a foreign class's block, and ordinary code, stay rejected.

class Owner {
	static readonly k: int32 = 1;
}

class Other {
	static { Owner.k = 2; }
}

function main(): int32 { return Owner.k - 1; }
const rc = main();
if (rc != 0) { process.exit(rc); }
