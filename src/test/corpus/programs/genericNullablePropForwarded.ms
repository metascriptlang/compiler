// @stdout: true|Ada|true|x|ok|ok
struct Payload { name: string; }
function take<P>(value: P | null): P | null { return value; }
function forward<P>(props: { value?: P | null }): P | null {
	return take<P>(props.value);
}

class Nav<P> {
	last: P | null = null;
	run(fn: () => void): void { fn(); }
	go(params: P | null): void {
		this.run((): void => {
			if (params !== null) { this.last = params; }
		});
	}
}

const absent = forward<Payload>({});
const present = forward<Payload>({ value: { name: "Ada" } });
const absentNum = forward<int32>({});
const presentStr = forward<string>({ value: "x" });
const n = new Nav<string>();
n.go("x");
const m = new Nav<int32>();
m.go(3);
console.log([
	absent === null,
	present !== null ? present.name : "none",
	absentNum === null,
	presentStr,
	n.last === null ? "bad" : "ok",
	m.last === null ? "bad" : "ok",
].join("|"));
