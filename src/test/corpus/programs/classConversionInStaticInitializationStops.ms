// @exit: 1
// @stdout: Source is not Target
// @xfail(danger): unchecked class conversions do not stop
// @xfail(raiser): static initialization blocks do not execute on this backend

class Source { marker: int32 = 2; }
console.log("before");
class Target {
	marker: int32 = 1;
	static {
		const wrong = new Source() as Target;
		console.log(`after ${wrong.marker}`);
	}
}
console.log("after init");
