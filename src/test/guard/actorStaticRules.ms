// GUARD-JS
// GUARD-CHECK-FAIL an actor's static 'n' is shared by every instance across threads, so it must be 'static readonly'
// GUARD-CHECK-FAIL can still be mutated through the readonly static 'xs'

actor A {
	static n: int32 = 0;
	static readonly xs: int32[] = [1, 2];
	ping(): int32 { return 1; }
}

const rc: int32 = 0;
if (rc != 0) { process.exit(rc); }
