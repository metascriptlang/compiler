// GUARD-OS bare
// GUARD-CHECK-FAIL async/await is unsupported under the freestanding runtime
// GUARD-CHECK-FAIL FREESTANDING E01
// A bare build refuses async at check time whatever its memory mode: under its DRC default it has no
// dispatcher either. RED MEANS the refusal keys on manual memory again, so bare async reaches the C compiler.
async function later(): Promise<int32> { // GUARD-REFUSED
	return 1;
}

const value = await later(); // GUARD-REFUSED
console.log(value);
