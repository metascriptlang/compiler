class ThunkCell { n: int32 = 0; }

async function constructedObjectWrite(): Promise<int32> {
	return await spawn((): int32 => {
		const cell = new ThunkCell();
		cell.n = 4;
		return cell.n;
	});
}

async function constructedErrorThrow(): Promise<string> {
	try {
		await spawn((): int32 => { throw new Error("boom"); });
		return "returned";
	} catch (e) {
		return e.message;
	}
}

async function constructedErrorType(): Promise<int32> {
	return await spawn((): int32 => {
		const made = new Error("x");
		const typed: Error = made;
		return typed.message.length;
	});
}

test "spawnThunkValues: a thunk writes the object it constructs" {
	assert await constructedObjectWrite() == 4;
}

test "spawnThunkValues: an Error a thunk constructs and throws reaches the awaiting parent" {
	assert await constructedErrorThrow() == "boom";
}

test "spawnThunkValues: an Error a thunk constructs keeps the Error type" {
	assert await constructedErrorType() == 1;
}
