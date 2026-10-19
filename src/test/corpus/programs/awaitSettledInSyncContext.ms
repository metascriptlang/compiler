// @stdout: t1 a1 t2a t2b a2 t3 a3 c1 a4 c2 a5 s1 a6w n v1 a7 p1 a8
// @xfail(raiser): raiser-solid owns Raiser Promise APIs; the Raiser resumes an await of a finished future at once
// note: an await outside an async function (module top level, a nested block) resumes behind the callbacks
// queued before it, as in TypeScript, whether the promise is already settled or still pending: one callback (t1 a1),
// two in queue order (t2a t2b a2), inside a block (t3 a3), a string or void value (s1 a6w, v1 a7) and a timer (p1 a8).
// A callback queued while the await waits its turn runs after the await resumes (c1 a4 c2).

let out = "";

function note(s: string): void {
	out += (out == "" ? "" : " ") + s;
}

async function word(): Promise<string> {
	return "w";
}

async function nothing(): Promise<void> {
	note("n");
}

Promise.resolve(0).then((v: int32): void => note("t1"));
await Promise.resolve(0);
note("a1");

Promise.resolve(0).then((v: int32): void => note("t2a"));
Promise.resolve(0).then((v: int32): void => note("t2b"));
await Promise.resolve(0);
note("a2");

if (out != "") {
	Promise.resolve(0).then((v: int32): void => note("t3"));
	await Promise.resolve(0);
	note("a3");
}

Promise.resolve(0).then((v: int32): void => note("c1")).then((): void => note("c2"));
await Promise.resolve(0);
note("a4");
await Promise.resolve(0);
note("a5");

Promise.resolve(0).then((v: int32): void => note("s1"));
const w = await word();
note("a6" + w);

Promise.resolve(0).then((v: int32): void => note("v1"));
await nothing();
note("a7");

Promise.resolve(0).then((v: int32): void => note("p1"));
await sleepAsync(0);
note("a8");
console.log(out);
