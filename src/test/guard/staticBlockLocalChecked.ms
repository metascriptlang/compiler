// GUARD-JS
// GUARD-CHECK-FAIL cannot assign to 'k' because it is a read-only property
// The static block of a class declared inside a function body is type-checked
// like any other class member.

class Owner {
	static readonly k: int32 = 1;
}

function local(): int32 {
	class L {
		static a: int32 = 0;
		static { Owner.k = 2; }
	}
	return L.a;
}

const rc = local();
if (rc != 0) { process.exit(rc); }
