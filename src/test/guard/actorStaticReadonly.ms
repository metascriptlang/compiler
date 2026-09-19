// GUARD-JS

function seven(): int32 { return 7; }

actor Act {
	static readonly k: int32 = seven();
	static readonly label: string = "act";
	static readonly doubled: int32 = 0;
	static { Act.doubled = Act.k * 2; }
	get(): int32 { return Act.k + Act.doubled; }
	name(): string { return Act.label; }
}

function expect(actual: int32, want: int32, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

async function main(): Promise<int32> {
	let rc: int32 = 0;
	rc += expect(Act.k, 7, "computedReadonlyStaticFromModule");
	rc += expect(Act.doubled, 14, "staticBlockAssignsReadonly");
	const a = new Act();
	const b = new Act();
	const va = await a.get();
	const vb = await b.get();
	rc += expect(va + vb, 42, "readonlyStaticFromActorMethods");
	const n = await a.name();
	if (n != "act") {
		console.log(`GUARD-FAIL stringStatic: got ${n}`);
		rc += 1;
	}
	if (rc == 0) { console.log("GUARD-OK actorStaticReadonly"); }
	return rc;
}

const rc = await main();
if (rc != 0) { process.exit(rc); }
