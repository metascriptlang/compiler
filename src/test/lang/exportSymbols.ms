@exportName("namedExportAnswer")

function localAnswer(): int32 { return 42; }

@exportName

export function bareExportAnswer(): int32 { return 7; }

@exportName("namedExportAdd")

function localAdd(value: int32): int32 { return value + 9; }

extern function namedExportAnswer(): int32;

extern function namedExportAdd(value: int32): int32;

test "exportSymbols: explicit and bare export names bind executable symbols with their declared signatures" {
	assert namedExportAnswer() == 42;
	assert bareExportAnswer() == 7;
	assert namedExportAdd(3) == 12;
	assert namedExportAdd(-9) == 0;
}
