// @stdout: narrowed wavy,none kept wavy,none returned solid,dots,none
// @stdout: widened a,a,a,none numbers 2,three,none instances some,none
// note: `"a" | "b" | null` is stored like `string | null` and `1 | 2 | null` like `int32 | null`, so a nullable literal union narrowed by a guard, widened to a larger literal set or widened to its base meets the target carrier unchanged. Before, each literal set had its own C carrier and every such use failed clang. A generic still gets one instance per literal set. Same output on every backend.
type Style = "solid" | "wavy" | "dotted";

function draw(line: "solid" | "wavy" | null): string {
	return line === null ? "none" : line;
}

function narrowed(own: Style | null): string {
	if (own !== null && own !== "solid" && own !== "wavy") {
		throw new Error(`not drawn: ${own as string}`);
	}
	return draw(own);
}

function kept(own: Style | null): string {
	if (own !== null && own !== "solid" && own !== "wavy") {
		throw new Error(`not drawn: ${own as string}`);
	}
	const line: "solid" | "wavy" | null = own;
	return line === null ? "none" : line;
}

function returned(own: Style | null): string {
	if (own !== null && own !== "solid" && own !== "wavy") return "dots";
	return draw(own);
}

function ab(): "a" | "b" | null { return "a"; }
function none(): "a" | "b" | null { return null; }

function widened(): string {
	const n = ab();
	const toBase: string | null = n;
	const toWider: "a" | "b" | "c" | null = n;
	const single: "a" | null = "a";
	const fromSingle: "a" | "b" | null = single;
	const absent: string | null = none();
	return [toBase ?? "none", toWider ?? "none", fromSingle ?? "none", absent ?? "none"].join(",");
}

function low(x: 1 | 2 | null): string { return x === null ? "none" : x.toString(); }

function numbers(x: 1 | 2 | 3 | null): string {
	if (x !== null && x !== 1 && x !== 2) return "three";
	return low(x);
}

function show<T>(x: T): string { return x === null ? "none" : "some"; }
function st(): string | null { return null; }

console.log("narrowed " + narrowed("wavy") + "," + narrowed(null)
	+ " kept " + kept("wavy") + "," + kept(null)
	+ " returned " + returned("solid") + "," + returned("dotted") + "," + returned(null));
console.log("widened " + widened()
	+ " numbers " + numbers(2) + "," + numbers(3) + "," + numbers(null)
	+ " instances " + show(ab()) + "," + show(st()));
