// @stdout: outer 2

function queue(): void {
	const outer = "outer-" + "z".repeat(30);
	Promise.resolve(1).then((v: int32): void => {
		Promise.resolve(v + 1).then((w: int32): void => { console.log(`${outer.slice(0, 5)} ${w}`); });
	});
}
queue();
