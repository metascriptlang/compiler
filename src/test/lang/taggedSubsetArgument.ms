enum SubsetKind { Accepted, Status, Failed, Gone }
struct SubsetReply = match (kind: SubsetKind) {
	SubsetKind.Accepted => { pid: int32 },
	SubsetKind.Status => { count: int32 },
	SubsetKind.Failed => { message: string },
	SubsetKind.Gone => { code: int32 },
};

function subsetViaResult(reply: SubsetReply): Result<SubsetReply, string> {
	if (reply.kind == SubsetKind.Failed) { return Result.err(reply.message); }
	return Result.ok<SubsetReply, string>(reply);
}

function subsetViaCall(reply: SubsetReply): string {
	if (reply.kind == SubsetKind.Failed) { return "failed"; }
	return JSON.stringify(subsetTake(reply));
}

function subsetTake(reply: SubsetReply): SubsetReply { return reply; }

function subsetViaReturn(reply: SubsetReply): SubsetReply {
	if (reply.kind == SubsetKind.Failed) { return reply; }
	return reply;
}

function subsetViaLocal(reply: SubsetReply): string {
	if (reply.kind == SubsetKind.Failed) { return "failed"; }
	const wide: SubsetReply = reply;
	return JSON.stringify(wide);
}

function subsetTwoOfFour(reply: SubsetReply): Result<SubsetReply, string> {
	if (reply.kind == SubsetKind.Failed || reply.kind == SubsetKind.Gone) { return Result.err("no"); }
	return Result.ok<SubsetReply, string>(reply);
}

test "taggedSubsetArgument: a two-variant subset is an explicit generic argument of its union" {
	const a = subsetViaResult({ kind: SubsetKind.Accepted, pid: 7 });
	const s = subsetViaResult({ kind: SubsetKind.Status, count: 9 });
	assert a.ok && JSON.stringify(a.value) == "{\"kind\":\"Accepted\",\"pid\":7}";
	assert s.ok && JSON.stringify(s.value) == "{\"kind\":\"Status\",\"count\":9}";
}

test "taggedSubsetArgument: a subset at a plain call, a return and a local" {
	assert subsetViaCall({ kind: SubsetKind.Status, count: 9 }) == "{\"kind\":\"Status\",\"count\":9}";
	assert subsetViaReturn({ kind: SubsetKind.Accepted, pid: 3 }).kind == SubsetKind.Accepted;
	assert subsetViaLocal({ kind: SubsetKind.Accepted, pid: 1 }) == "{\"kind\":\"Accepted\",\"pid\":1}";
}

test "taggedSubsetArgument: a 2-of-4 subset keeps discriminator and payload" {
	const a = subsetTwoOfFour({ kind: SubsetKind.Accepted, pid: 7 });
	const s = subsetTwoOfFour({ kind: SubsetKind.Status, count: 9 });
	assert a.ok && JSON.stringify(a.value) == "{\"kind\":\"Accepted\",\"pid\":7}";
	assert s.ok && JSON.stringify(s.value) == "{\"kind\":\"Status\",\"count\":9}";
	assert !subsetTwoOfFour({ kind: SubsetKind.Gone, code: 1 }).ok;
}
