// `await thenable` calls `then` from a queued job, as a settled promise's callback runs: after the
// caller's next statement, never inside the await.
// @stdout: start|after call|then called|awaited 5
// @exit: 0

const out: string[] = [];

class Now {
	then(onFulfilled: (v: int32) => void): void {
		out.push("then called");
		onFulfilled(5);
	}
}

async function user(): Promise<void> {
	out.push("start");
	const v = await new Now();
	out.push(`awaited ${v}`);
	console.log(out.join("|"));
}

user();
out.push("after call");
