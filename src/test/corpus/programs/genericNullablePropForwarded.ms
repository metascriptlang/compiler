// @stdout: true|Ada|true|x|ok|ok|ok|ok|true|true|Bo|true|Cy
interface Named { name: string; }
struct Payload { name: string; }
function take<P>(value: P | null): P | null { return value; }
function forward<P>(props: { value?: P | null }): P | null {
	return take<P>(props.value);
}
function forwardRequired<P>(props: { value: P | null }): P | null {
	return take<P>(props.value);
}
function forwardNested<P>(props: { inner: { value?: P | null } }): P | null {
	return take<P>(props.inner.value);
}

class Nav<P> {
	last: P | null = null;
	run(fn: () => void): void { fn(); }
	go(params: P | null): void {
		this.run((): void => {
			if (params !== null) { this.last = params; }
		});
	}
	goDeep(params: P | null): void {
		this.run((): void => {
			this.run((): void => {
				if (params !== null) { this.last = params; }
			});
		});
	}
}

const absent = forward<Payload>({});
const present = forward<Payload>({ value: { name: "Ada" } });
const absentNum = forward<int32>({});
const presentStr = forward<string>({ value: "x" });
const presentNull = forward<Payload>({ value: null });
const requiredNull = forwardRequired<Payload>({ value: null });
const requiredValue = forwardRequired<Payload>({ value: { name: "Bo" } });
const nestedAbsent = forwardNested<Payload>({ inner: {} });
const nestedValue = forwardNested<Payload>({ inner: { value: { name: "Cy" } } });
const n = new Nav<string>();
n.go("x");
const m = new Nav<int32>();
m.go(3);
const q = new Nav<Named>();
q.go({ name: "q" });
const d = new Nav<string>();
d.goDeep("y");
console.log([
	absent === null,
	present !== null ? present.name : "none",
	absentNum === null,
	presentStr,
	n.last === null ? "bad" : "ok",
	m.last === null ? "bad" : "ok",
	q.last === null ? "bad" : "ok",
	d.last === null ? "bad" : "ok",
	presentNull === null,
	requiredNull === null,
	requiredValue !== null ? requiredValue.name : "none",
	nestedAbsent === null,
	nestedValue !== null ? nestedValue.name : "none",
].join("|"));
