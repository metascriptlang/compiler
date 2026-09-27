// @stdout: loop total=3 0/1 1/11 2/21
// @stdout: shared 7 8
// @stdout: header c5 u1 u2 u3 j1 j3 j4 j5
// @xfail(raiser): the Raiser VM cannot evaluate a loop label at comptime ('cannot evaluate 'label'')
// note: a closure made in a loop shares the function's variables and owns the bindings its iteration declares, one env per iteration shared by every closure of that iteration (JS per-iteration binding). A `let` of a for header is copied per iteration: a closure in the condition sees the running iteration, one in the update sees the next. Before the fix C gave every closure a private copy of every capture: total stayed 0, a later write to the function's variable was not seen, sibling closures of one iteration did not share their binding, and a header closure saw the wrong iteration.

type Thunk = () => string;
type Get = () => int32;
type Set = (v: int32) => void;

function loopExample(): string {
	let total: int32 = 0;
	const fns: (() => void)[] = [];
	const shows: Thunk[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		let j: int32 = i * 10;
		fns.push((): void => { total += i; });
		shows.push((): string => `${i}/${j}`);
		j = j + 1;
	}
	for (const f of fns) f();
	let s = `loop total=${total}`;
	for (const g of shows) s = s + " " + g();
	return s;
}

function iterationShared(): string {
	const gets: Get[] = [];
	const sets: Set[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		let y: int32 = i * 100;
		gets.push((): int32 => y);
		sets.push((v: int32): void => { y = v; });
	}
	sets[0](7);
	sets[1](8);
	return `shared ${gets[0]()} ${gets[1]()}`;
}

function outerShared(): string {
	let total: int32 = 0;
	const reads: Get[] = [];
	const adds: Set[] = [];
	let k: int32 = 0;
	while (k < 2) {
		const c: int32 = k;
		reads.push((): int32 => total + c);
		adds.push((v: int32): void => { total = total + v; });
		k++;
	}
	adds[0](5);
	adds[1](7);
	const afterAdds = total;
	total = 99;
	return `outer ${afterAdds} ${reads[0]()} ${reads[1]()}`;
}

function nested(): string {
	const fs: Get[] = [];
	for (let i: int32 = 0; i < 2; i++) {
		let acc: int32 = i * 100;
		for (let j: int32 = 0; j < 2; j++) {
			fs.push((): int32 => { acc = acc + 1; return acc * 10 + j; });
		}
	}
	let s = "nested";
	for (const f of fs) s = s + ` ${f()}`;
	return s;
}

function header(): string {
	const conds: Get[] = [];
	const keep = (into: Get[], f: Get): boolean => { into.push(f); return true; };
	for (let i: int32 = 0; i < 3 && keep(conds, (): int32 => i); i++) {
		i = i + 5;
	}
	const updates: Get[] = [];
	const step = (into: Get[], v: int32, f: Get): int32 => { into.push(f); return v + 1; };
	for (let i: int32 = 0; i < 3; i = step(updates, i, (): int32 => i)) {
		i = i + 0;
	}
	const jumps: Get[] = [];
	for (let i: int32 = 0; i < 8; i++) {
		jumps.push((): int32 => i);
		if (i % 2 == 0 && i < 4) {
			i = i + 1;
			continue;
		}
		if (i > 4) break;
	}
	let s = "header";
	for (const f of conds) s = s + ` c${f()}`;
	for (const f of updates) s = s + ` u${f()}`;
	for (const f of jumps) s = s + ` j${f()}`;
	return s;
}

class Counter {
	hits: int32 = 0;
	names: string[] = [];
}

function refsPerIteration(): string {
	const c = new Counter();
	const handlers: (() => void)[] = [];
	const labels: string[] = ["a", "bb", "ccc"];
	for (const label of labels) {
		const tag = label + "!";
		handlers.push((): void => {
			c.hits = c.hits + label.length;
			c.names.push(tag);
		});
	}
	for (const h of handlers) h();
	return `refs ${c.hits} ${c.names.join(",")}`;
}

function reportValue(actual: string, expected: string): void {
	assert actual == expected;
	console.log(actual);
}
reportValue(loopExample(), "loop total=3 0/1 1/11 2/21");
reportValue(iterationShared(), "shared 7 8");
reportValue(outerShared(), "outer 12 99 100");
reportValue(nested(), "nested 10 21 1010 1021");
reportValue(header(), "header c5 u1 u2 u3 j1 j3 j4 j5");
reportValue(refsPerIteration(), "refs 6 a!,bb!,ccc!");
