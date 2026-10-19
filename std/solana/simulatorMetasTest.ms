import { msSolLoadU32, msSolLoadU64, msSolLoadU8, msSolSpanAddress, msSolStoreU8, msSolWordsAddress } from "./memory";
import { MAX_CPI_ACCOUNTS, invokeMetas } from "./simulatorMetas";
import { parseInput } from "./simulatorContext";
import { serializeInput } from "./simulatorContextFixture";
import { msSolHostFaultCodeOf } from "./memory";

when (c) {
	import { msSolInvokeMetas } from "./kernel";

	import { msSolStoreU64 } from "./memory";

	extern function msSolHostEnter(input: uint64): void;
	extern function msSolHostInvokeSigned(instruction: uint64, infos: uint64, count: uint64, signers: uint64, signerCount: uint64): uint64;
	extern function msSolHostInvocationTotal(): uint64;
	extern function msSolHostInvocationAt(index: uint64): uint64;
}

let seenHeader: uint64[] = [];
let seenInfos: uint64[] = [];
let seenFlags: uint32[] = [];
let seenCount: uint64 = 0;
let seenSigners: uint64 = 0;
let seenSignerCount: uint64 = 0;

function record(instruction: uint64, infos: uint64, count: uint64, signers: uint64, signerCount: uint64): uint64 {
	seenHeader = [];
	seenInfos = [];
	seenFlags = [];
	for (let word: uint64 = 0; word < 5; word++) { seenHeader.push(msSolLoadU64(instruction + word * 8)); }
	for (let index: uint64 = 0; index < count; index++) {
		for (let word: uint64 = 0; word < 6; word++) { seenInfos.push(msSolLoadU64(infos + index * 56 + word * 8)); }
		seenFlags.push(msSolLoadU32(infos + index * 56 + 48));
	}
	seenCount = count;
	seenSigners = signers;
	seenSignerCount = signerCount;
	return 77;
}

test "the instruction header and each meta's account info are built from the account records and handed to the invoker" {
	const input = serializeInput([0, 1, 0], [5, 12, 5], [], 0x66);
	const base = msSolSpanAddress(input);
	let table: uint64[255] = [];
	parseInput(base, msSolWordsAddress(table));
	const first = table[0];
	const second = table[1];
	msSolStoreU8(second + 1, 0);
	let metas: uint64[4] = [];
	metas[0] = second + 8;
	metas[1] = 0x0100;
	metas[2] = first + 8;
	metas[3] = 0x0001;
	let program: uint8[32] = [];
	let data: uint8[3] = [];
	data[0] = 5;
	let signers: uint64[2] = [];
	const status = invokeMetas(msSolSpanAddress(program), msSolWordsAddress(metas), 2, msSolSpanAddress(data), 3, msSolWordsAddress(signers), 1, record);
	assert status == 77;
	assert seenHeader[0] == msSolSpanAddress(program) && seenHeader[1] == msSolWordsAddress(metas) && seenHeader[2] == 2 && seenHeader[3] == msSolSpanAddress(data) && seenHeader[4] == 3;
	assert seenCount == 2 && seenSigners == msSolWordsAddress(signers) && seenSignerCount == 1;
	assert seenInfos[0] == second + 8 && seenInfos[1] == second + 72 && seenInfos[2] == 12 && seenInfos[3] == second + 88 && seenInfos[4] == second + 40 && seenInfos[5] == 0;
	assert seenInfos[6] == first + 8 && seenInfos[7] == first + 72 && seenInfos[8] == 5 && seenInfos[9] == first + 88 && seenInfos[10] == first + 40;
	assert seenFlags[0] == 0x0100 && seenFlags[1] == 0x02000101;
	assert msSolLoadU8(base) == 3 && input.length > 0;
}

test "no metas still reaches the invoker with an empty account list, and more than 64 is refused with a fault" {
	let program: uint8[32] = [];
	let metas: uint64[2] = [];
	let data: uint8[1] = [];
	assert invokeMetas(msSolSpanAddress(program), msSolWordsAddress(metas), 0, msSolSpanAddress(data), 0, 0, 0, record) == 77;
	assert seenCount == 0 && seenHeader[2] == 0 && seenInfos.length == 0;
	assert MAX_CPI_ACCOUNTS == 64;
	assert invokeMetas(msSolSpanAddress(program), msSolWordsAddress(metas), 65, msSolSpanAddress(data), 0, 0, 0, record) == 0xffffffffffffffff;
	assert msSolHostFaultCodeOf() != 0;
}

function sameInvocation(left: uint64, right: uint64): boolean {
	for (let at: uint64 = 0; at < 32; at++) { if (msSolLoadU8(left + at) != msSolLoadU8(right + at)) { return false; } }
	const count = msSolLoadU64(left + 32);
	if (count != msSolLoadU64(right + 32) || msSolLoadU64(left + 48) != msSolLoadU64(right + 48)) { return false; }
	for (let at: uint64 = 0; at < count * 34; at++) {
		if (msSolLoadU8(msSolLoadU64(left + 40) + at) != msSolLoadU8(msSolLoadU64(right + 40) + at)) { return false; }
	}
	for (let at: uint64 = 0; at < msSolLoadU64(left + 48); at++) {
		if (msSolLoadU8(msSolLoadU64(left + 56) + at) != msSolLoadU8(msSolLoadU64(right + 56) + at)) { return false; }
	}
	return true;
}

test "the C host records the same invocation from the C inline builder and from the shared one" {
	when (c) {
		const input = serializeInput([0, 1, 0], [5, 12, 5], [], 0x66);
		const base = msSolSpanAddress(input);
		msSolHostEnter(base);
		let table: uint64[255] = [];
		parseInput(base, msSolWordsAddress(table));
		let program: uint8[32] = [];
		for (let k = 0; k < 32; k++) { program[k] = 0x55; }
		let data: uint8[3] = [];
		data[0] = 5;
		data[2] = 9;
		let metas: uint64[6] = [];
		metas[0] = table[1] + 8;
		metas[1] = 0x0100;
		metas[2] = table[0] + 8;
		metas[3] = 0x0001;
		metas[4] = table[2] + 8;
		metas[5] = 0x0101;
		const invoke = (a: uint64, b: uint64, c: uint64, d: uint64, e: uint64): uint64 => msSolHostInvokeSigned(a, b, c, d, e);
		const theirs = msSolInvokeMetas(msSolSpanAddress(program), msSolWordsAddress(metas), 3, msSolSpanAddress(data), 3, 0, 0);
		const mine = invokeMetas(msSolSpanAddress(program), msSolWordsAddress(metas), 3, msSolSpanAddress(data), 3, 0, 0, invoke);
		assert theirs == 0 && mine == 0 && msSolHostInvocationTotal() == 2;
		assert sameInvocation(msSolHostInvocationAt(0), msSolHostInvocationAt(1));
		assert msSolLoadU64(msSolHostInvocationAt(1) + 32) == 3 && input.length > 0;
		msSolStoreU64(msSolSpanAddress(program), 0);
		const refused = invokeMetas(msSolSpanAddress(program), msSolWordsAddress(metas), 3, msSolSpanAddress(data), 3, 0, 0, invoke);
		assert refused == msSolInvokeMetas(msSolSpanAddress(program), msSolWordsAddress(metas), 3, msSolSpanAddress(data), 3, 0, 0);
	}
}
