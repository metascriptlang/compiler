// @stdout: sync after sum
// @stdout: loop 0
// @stdout: loop 1
// @stdout: loop 2
// @stdout: total 3
// @xfail(raiser): raiser-solid owns Raiser Promise APIs; the Raiser resumes an await of a finished future at once
// note: every await of Promise.resolve(i) in a loop resumes in a later job, so the caller's next statement runs before the first iteration's tail, as in TypeScript.

async function sum(): Promise<void> {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		total += await Promise.resolve(i);
		console.log("loop " + i.toString());
	}
	console.log("total " + total.toString());
}

sum();
console.log("sync after sum");
