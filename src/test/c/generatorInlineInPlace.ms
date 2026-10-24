import { compileToC } from "../helpers";

const generators = `
	function* count(n: int32): Iterator<int32> {
		for (let i: int32 = 0; i < n; i++) {
			yield i;
		}
	}
	function* tail(this xs: string[], from: int32): Iterator<string> {
		for (let i: int32 = from; i < xs.length; i++) {
			yield xs[i];
		}
	}
`;

function emitFor(consumer: string): string {
	const c = compileToC(generators + consumer);
	return c.ok ? c.value : "";
}

test "E2E C: a for-of over a call to a generator drives no iterator" {
	const c = emitFor(`
		let sum: int32 = 0;
		for (const x of count(5)) {
			if (x == 3) break;
			sum += x;
		}
		console.log(sum);
	`);
	assert c != "";
	assert !c.contains("dollariter");
}

test "E2E C: a for-of over an extension generator on an array drives no iterator" {
	const c = emitFor(`
		const words: string[] = ["a", "b", "c"];
		let joined: string = "";
		for (const w of words.tail(1)) {
			joined = joined + w;
		}
		console.log(joined);
	`);
	assert c != "";
	assert !c.contains("dollariter");
}

test "E2E C: a stored generator is driven through its iterator" {
	const c = emitFor(`
		const it = count(5);
		for (const x of it) {
			console.log(x);
		}
	`);
	assert c != "";
	assert c.contains("dollariter");
}
