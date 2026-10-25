// @stdout: 7
// @stdout: end
// note: the same call through a narrowed nullable function field of a generic class, read from `this`.

class Box<T> {
	stop: (() => T) | null = null;

	run(): void {
		if (this.stop != null) console.log(this.stop());
	}
}

const b = new Box<int32>();
b.stop = (): int32 => 7;
b.run();
const c = new Box<int32>();
c.run();
console.log("end");
