// @stdout: sync after run
// @stdout: run got 7
// @xfail(raiser): raiser-solid owns Raiser Promise APIs; the Raiser resumes an await of a finished future at once
// note: an async method awaiting another async method that returns without awaiting resumes after its caller's next statement, as in TypeScript.

class Loader {
	async value(): Promise<int32> {
		return 7;
	}

	async run(): Promise<void> {
		const v = await this.value();
		console.log("run got " + v.toString());
	}
}

const loader = new Loader();
loader.run();
console.log("sync after run");
