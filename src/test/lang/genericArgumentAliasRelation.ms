struct HiddenRecord { bytes: uint8[4]; }
export type PublicRecord = HiddenRecord;

function plainRecord(): Result<HiddenRecord, int32> {
	const value: HiddenRecord = { bytes: [1, 2, 3, 4] };
	return Result.ok(value);
}
function aliasedRecord(): Result<PublicRecord, int32> { return plainRecord(); }

test "a transparent record alias stays assignable inside Result type arguments" {
	const result = aliasedRecord();
	assert result.ok;
	if (result.ok) { assert result.value.bytes[3] == 4; }
}

struct HiddenFlag { flag: boolean; }
type PublicFlag = HiddenFlag;
function aliasedFlag(): Result<PublicFlag, int32> {
	const result: Result<HiddenFlag, int32> = Result.ok({ flag: true });
	return result;
}

test "a transparent boolean-record alias stays assignable inside Result type arguments" {
	const result = aliasedFlag();
	assert result.ok;
	if (result.ok) { assert result.value.flag; }
}

type PublicCount = uint64;
function aliasedCount(): Result<PublicCount, int32> {
	const result: Result<uint64, int32> = Result.ok(13);
	return result;
}

test "a transparent scalar alias stays assignable inside Result type arguments" {
	const result = aliasedCount();
	assert result.ok;
	if (result.ok) { assert result.value == 13; }
}

type PublicRecordTwice = PublicRecord;
function aliasedTwice(): Result<PublicRecordTwice, int32> { return plainRecord(); }

test "a nested record alias and an array of aliases share the canonical instantiation" {
	const result = aliasedTwice();
	assert result.ok;
	if (result.ok) { assert result.value.bytes[0] == 1; }
	const aliases: PublicRecord[] = [{ bytes: [9, 8, 7, 6] }];
	const plain: HiddenRecord[] = aliases;
	assert plain[0].bytes[3] == 6;
}
