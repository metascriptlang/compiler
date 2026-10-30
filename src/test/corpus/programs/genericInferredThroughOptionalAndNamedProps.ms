// @stdout: a|a|a|d|x|7
function pickDirect<T>(spec: { ios?: T | null; android?: T | null; default?: T | null }): T {
	if (spec.android != null) { return spec.android as T; }
	return spec.default as T;
}
interface Spec<T> { ios?: T | null; android?: T | null; default?: T | null }
function pickNamed<T>(spec: Spec<T>): T {
	if (spec.android != null) { return spec.android as T; }
	return spec.default as T;
}
class P {
	static pick<T>(spec: { ios?: T | null; android?: T | null; default?: T | null }): T {
		if (spec.android != null) { return spec.android as T; }
		return spec.default as T;
	}
}
function pickPlain<T>(spec: { ios?: T; android?: T; default?: T }): T {
	if (spec.android != null) { return spec.android as T; }
	return spec.default as T;
}

interface Props<T> { data: T[]; renderItem: (item: T) => string; }
function rows<T>(props: Props<T>): string { return props.renderItem(props.data[0]); }
function component<P>(fn: (props: P) => string, props: P): string { return fn(props); }
function label(item: string): string { return item; }
function num(item: number): string { return item.toString(); }

const a = pickDirect({ android: "a", default: "d" });
const b = pickNamed({ android: "a", default: "d" });
const c = P.pick<string>({ android: "a", default: "d" });
const d = pickPlain({ default: "d" });
console.log([a, b, c, d, component(rows, { data: ["x"], renderItem: label }), component(rows, { data: [7], renderItem: num })].join("|"));
