// @xfail(raiser): the Raiser VM cannot tell a number from a function inside one union at comptime
// @stdout: 1 2 0 5 2 1
// @exit: 0
// note: a value typed as one enum member meeting a union that holds the whole enum (a signal setter taking a value or an updater) used to reach the call as the bare enum constant, where C wants the address of the tagged union, so clang refused it. A member written in a macro argument comes back from the macro typed as its member, which is how a JSX event handler delivers `setLens(Lens.Compute)`; a local annotated with the member type is the same shape without a macro. Handler, second member, handler in a handler, a number control, an updater and the annotated local.

import { handler } from "./decl";

enum Lens { Status, Compute, Project }

type Setter<T> = (v: T | ((prev: T) => T)) => void;

function signal<T>(initial: T): [() => T, Setter<T>] {
	let current = initial;
	const set = (v: T | ((prev: T) => T)): void => {
		if (typeof v == "function") { current = (v as (prev: T) => T)(current); } else { current = v as T; }
	};
	return [(): T => current, set];
}

function press(onPress: () => void): void {
	onPress();
}

const [lens, setLens] = signal(Lens.Status);
const [count, setCount] = signal(1);
const seen: string[] = [];
const note = (): void => { seen.push((lens() as number).toString()); };

press(handler((): void => { setLens(Lens.Compute); }));
note();
press(handler((): void => { setLens(Lens.Project); }));
note();
press(handler((): void => { press(handler((): void => { setLens(Lens.Status); })); }));
note();
press(handler((): void => { setCount(5); }));
seen.push(count().toString());
press(handler((): void => { setLens((prev: Lens): Lens => prev == Lens.Status ? Lens.Project : Lens.Compute); }));
note();
const member: Lens.Compute = Lens.Compute;
setLens(member);
note();
console.log(seen.join(" "));
