// @stdout: argument 3
// @stdout: return 1,2,3
// @stdout: property 30
// @stdout: element 7 8
// @stdout: immediate 11
// @stdout: assigned 5
// @stdout: if body 3
// @stdout: arrow body 9
// @stdout: async body 4
// note: a `function*` expression is lowered wherever it appears, as every routine is. Before the fix C lowered it only as a `const` initializer, and in any other position it reached codegen with its `yield` unlowered.

interface Source {
	gen: () => Iterator<int32>;
}

function sum(it: Iterator<int32>): int32 {
	let s: int32 = 0;
	for (const v of it) s = s + v;
	return s;
}

function countTo(n: int32): () => Iterator<int32> {
	return function* (): Iterator<int32> {
		for (let i: int32 = 1; i <= n; i++) yield i;
	};
}

function joined(it: Iterator<int32>): string {
	const parts: string[] = [];
	for (const v of it) parts.push(String(v));
	return parts.join(",");
}

console.log(`argument ${sum((function* (): Iterator<int32> { yield 1; yield 2; })())}`);
console.log(`return ${joined(countTo(3)())}`);

const source: Source = { gen: function* (): Iterator<int32> { yield 10; yield 20; } };
console.log(`property ${sum(source.gen())}`);

const gens: (() => Iterator<int32>)[] = [function* (): Iterator<int32> { yield 7; }, function* (): Iterator<int32> { yield 8; }];
console.log(`element ${sum(gens[0]())} ${sum(gens[1]())}`);

console.log(`immediate ${sum(function* (): Iterator<int32> { yield 5; yield 6; }())}`);

let later: () => Iterator<int32> = countTo(0);
later = function* (): Iterator<int32> { yield 2; yield 3; };
console.log(`assigned ${sum(later())}`);

function inIfBody(flag: boolean): int32 {
	let s: int32 = 0;
	if (flag) {
		function* g(): Iterator<int32> { yield 1; yield 2; }
		s = sum(g());
	}
	return s;
}
console.log(`if body ${inIfBody(true)}`);

const inArrow = (k: int32): int32 => {
	function* g(): Iterator<int32> { yield k; yield k * 2; }
	return sum(g());
};
console.log(`arrow body ${inArrow(3)}`);

async function inAsync(): Promise<int32> {
	function* g(): Iterator<int32> { yield 1; yield 3; }
	await Promise.resolve(0);
	return sum(g());
}
console.log(`async body ${await inAsync()}`);
