const TAG: string = "seed";
let calls: uint64 = 0;

export function tagLength(): uint64 {
	return TAG.length as uint64;
}

export function countCall(): uint64 {
	calls = calls + 1;
	return calls;
}

export function four(): uint64 {
	return 4;
}
