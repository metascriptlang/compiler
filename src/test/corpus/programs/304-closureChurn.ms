// Parity program — closure churn: envs created and dropped in bulk, string
// payloads captured, relayed, thrown across. The SAN lane reads this file as
// a leak/double-free probe; keep every count fixed and every print ordered.

type Producer = () => string;

function heavy(tag: string, n: int64): string {
	let s = tag;
	for (let i: int64 = 0; i < n; i = i + 1) {
		s = s + s;
	}
	return s;
}

function makeProducer(tag: string): Producer {
	const payload = heavy(tag, 6);
	return (): string => payload;
}

function relay(p: Producer): Producer {
	return p;
}

function main(): void {
	let kept = "";
	for (let i: int64 = 0; i < 2000; i = i + 1) {
		const p = makeProducer("t" + (i % 10).toString());
		if (i % 500 == 0) {
			kept = kept + p().length.toString() + ",";
		}
	}
	console.log("keptLens=" + kept);

	for (let i: int64 = 0; i < 1000; i = i + 1) {
		const q = relay(makeProducer("r"));
		if (i == 999) { console.log("lastLen=" + q().length.toString()); }
	}

	let caught: int64 = 0;
	for (let i: int64 = 0; i < 200; i = i + 1) {
		try {
			const p = makeProducer("e");
			if (p().length > 0) { throw "drop " + i.toString(); }
		} catch (e) {
			caught = caught + 1;
		}
	}
	console.log("caught=" + caught.toString());
}
main();
