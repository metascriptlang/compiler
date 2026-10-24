// SELFTEST-RED has no ledger row
// GUARD-BALANCE SelftestGhost

class SelftestGhost {
	n: int32 = 0;
}

function make(build: boolean): SelftestGhost | null {
	return build ? new SelftestGhost() : null;
}

console.log(make(false) == null ? "none" : "some");
console.log("GUARD-OK");
