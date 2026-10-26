import { compileToC } from "../helpers";

function subTraceBody(c: string): string {
	const lines = c.split("\n");
	let body = "";
	let inside = false;
	for (const line of lines) {
		if (!inside && line.startsWith("void Sub_") && line.indexOf("Trace(") > 0 && line.endsWith("{")) inside = true;
		if (inside) {
			body += line + "\n";
			if (line == "}") break;
		}
	}
	return body;
}

function occurrences(text: string, needle: string): int32 {
	let n = 0;
	let at = text.indexOf(needle);
	while (at >= 0) {
		n += 1;
		at = text.indexOf(needle, at + needle.length);
	}
	return n;
}

interface InstanceShape {
	label: string;
	source: string;
	field: string;
}

test "a generic subclass built only from a dependent instantiation traces each inherited field once" {
	const base = "class Base { touch: () => void = (): void => {}; } ";
	const sub = "class Sub<V> extends Base { value: V; constructor(value: V) { super(); this.value = value; } } ";
	const cases: InstanceShape[] = [
		{ label: "generic function", source: base + sub + "function make<V>(v: V): Base { return new Sub<V>(v); } const x = make<int32>(1);", field: "touch" },
		{ label: "generic method", source: base + sub + "class Holder<V> { slots: Base[] = []; add(v: V): void { this.slots.push(new Sub<V>(v)); } } const h = new Holder<int32>(); h.add(1);", field: "touch" },
		{ label: "depth 2", source: "class Base { a: () => void = (): void => {}; } class Mid extends Base { b: () => void = (): void => {}; } class Sub<V> extends Mid { v: V; constructor(v: V) { super(); this.v = v; } } function make<V>(v: V): Base { return new Sub<V>(v); } const x = make<int32>(1);", field: "a" },
		{ label: "generic base", source: "class Base<T> { touch: () => void = (): void => {}; t: T | null = null; } class Sub<V> extends Base<V> { c: () => void = (): void => {}; } function make<V>(v: V): Base<V> { return new Sub<V>(); } const x = make<int32>(1);", field: "touch" },
		{ label: "concrete instance", source: base + sub + "const y = new Sub<int32>(2);", field: "touch" },
	];
	for (const c of cases) {
		const result = compileToC(c.source);
		assert result.ok, result.ok ? "" : result.error;
		const trace = subTraceBody(result.value);
		assert trace != "", c.label + ": Sub trace hook emitted";
		assert occurrences(trace, `msClosureTrace((*self).${c.field}, callback)`) == 1, c.label + ": " + c.field + " traced once";
		assert trace.indexOf("Base_") < 0 && trace.indexOf("Mid_") < 0, c.label + ": no base hook call beside the flat fields";
	}
}
