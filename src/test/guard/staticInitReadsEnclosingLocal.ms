// GUARD-JS
// GUARD-CHECK-FAIL cannot read the enclosing local 'k'
// GUARD-CHECK-FAIL cannot read the parameter 'n'

function local(n: int32): int32 {
	const k: int32 = n * 2;
	class L {
		static a: int32 = k + 1;
		static b: int32 = 0;
		static { L.b = n; }
	}
	return L.a + L.b;
}

const rc = local(1);
if (rc != 0) { process.exit(rc); }
