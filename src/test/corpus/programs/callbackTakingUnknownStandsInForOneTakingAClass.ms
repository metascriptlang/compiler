// @stdout: error boom
// @stdout: foo 3
// @stdout: maybe foo 3
// @stdout: stored error stored

class Foo { n: int32 = 3; }

function onError(cb: (e: Error) => void): void { cb(new Error("boom")); }
function onFoo(cb: (x: Foo) => void): void { cb(new Foo()); }

function describe(reason: unknown): string {
	if (reason instanceof Error) return "error " + (reason as Error).message;
	if (reason instanceof Foo) return "foo " + (reason as Foo).n.toString();
	return "other";
}

onError((reason: unknown): void => { console.log(describe(reason)); });
onFoo((reason: unknown): void => { console.log(describe(reason)); });
onFoo((reason: unknown | null): void => { console.log("maybe " + (reason == null ? "null" : describe(reason))); });

const stored: (e: Error) => void = (reason: unknown): void => { console.log("stored " + describe(reason)); };
stored(new Error("stored"));
