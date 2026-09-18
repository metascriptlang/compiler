// GUARD-JS
// GUARD-CHECK-FAIL static blocks are not supported in actors
// An actor has no static run-part: the block is rejected instead of being
// dropped on one backend and run on the other.

actor A {
	static { console.log("never"); }
	ping(): int32 { return 1; }
}

const rc: int32 = 0;
if (rc != 0) { process.exit(rc); }
