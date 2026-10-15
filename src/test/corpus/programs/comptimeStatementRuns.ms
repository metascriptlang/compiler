// @stdout: main done
@comptime { const n: int32 = 2; console.log(`ct ${n * 21}`); }

function work(): string {
	@comptime { const k: int32 = 3; console.log(`inner ${k}`); }
	return "done";
}

console.log(`main ${work()}`);
