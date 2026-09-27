function pick<T, U>(a: T, b: U): T { return a; }

function instantiateCalls(): int32 {
	const v01 = pick<int32, boolean>(1, true);
	const v02 = pick<int32, boolean>(1, true);
	const v03 = pick<int32, boolean>(1, true);
	const v04 = pick<int32, boolean>(1, true);
	const v05 = pick<int32, boolean>(1, true);
	const v06 = pick<int32, boolean>(1, true);
	const v07 = pick<int32, boolean>(1, true);
	const v08 = pick<int32, boolean>(1, true);
	const v09 = pick<int32, boolean>(1, true);
	const v10 = pick<int32, boolean>(1, true);
	const v11 = pick<int32, boolean>(1, true);
	const v12 = pick<int32, boolean>(1, true);
	return v01 + v02 + v03 + v04 + v05 + v06 + v07 + v08 + v09 + v10 + v11 + v12;
}

function instantiateConstructors(): int32 {
	let m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000 = new Map<uint64, int32>();
	m0000.set(1 as uint64, 12);
	return m0000.size as int32;
}

test "nominalInstantiation: explicit type args bind in their own module" {
	assert instantiateCalls() == 12;
	assert instantiateConstructors() == 1;
}
