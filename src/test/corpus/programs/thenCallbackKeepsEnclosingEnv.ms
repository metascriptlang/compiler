// @stdout: x
// @stdout: y
// @stdout: inner y

function outer(next: string): void {
	const t = (): void => {
		Promise.resolve(1).then((v: int32): void => { console.log(next); });
	};
	t();
}

function nested(next: string): void {
	const t = (): void => {
		Promise.resolve(1).then((v: int32): void => {
			console.log(next);
			Promise.resolve(2).then((w: int32): void => { console.log("inner " + next); });
		});
	};
	t();
}

outer("x");
nested("y");
