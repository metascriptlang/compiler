import { msSolHostRaise, msSolLoadU32, msSolLoadU64, msSolStoreU32, msSolStoreU64, msSolWordsAddress } from "./memory";

const REFUSED: uint64 = 0xffffffffffffffff;

export const MAX_CPI_ACCOUNTS: uint64 = 64;
const INFO_SIZE: uint64 = 56;

export type Invoker = (instruction: uint64, infos: uint64, count: uint64, signers: uint64, signerCount: uint64) => uint64;

// The runtime's SolAccountInfo of each meta's record and the instruction header, built
// in the caller's frames (`infos` of 448 words, `header` of 5) and handed to `invoke` (msSolInvokeSigned on chain,
// the simulator's dispatcher here)
export function invokeMetasAt(
	infos: uint64,
	header: uint64,
	program: uint64,
	metas: uint64,
	count: uint64,
	data: uint64,
	length: uint64,
	signers: uint64,
	signerCount: uint64,
	invoke: Invoker,
): uint64 {
	if (count > MAX_CPI_ACCOUNTS) {
		msSolHostRaise(REFUSED, "solana invoke: more than 64 accounts in one instruction");
		return REFUSED;
	}
	for (let index: uint64 = 0; index < count; index++) {
		const at = infos + index * INFO_SIZE;
		const key = msSolLoadU64(metas + index * 16);
		const record = key - 8;
		msSolStoreU64(at, key);
		msSolStoreU64(at + 8, record + 72);
		msSolStoreU64(at + 16, msSolLoadU64(record + 80));
		msSolStoreU64(at + 24, record + 88);
		msSolStoreU64(at + 32, record + 40);
		msSolStoreU64(at + 40, 0);
		msSolStoreU32(at + 48, msSolLoadU32(record + 1));
	}
	msSolStoreU64(header, program);
	msSolStoreU64(header + 8, metas);
	msSolStoreU64(header + 16, count);
	msSolStoreU64(header + 24, data);
	msSolStoreU64(header + 32, length);
	return invoke(header, infos, count, signers, signerCount);
}

@noinline export function invokeMetas(
	program: uint64,
	metas: uint64,
	count: uint64,
	data: uint64,
	length: uint64,
	signers: uint64,
	signerCount: uint64,
	invoke: Invoker,
): uint64 {
	let infoWords: uint64[448] = [];
	let headerWords: uint64[5] = [];
	return invokeMetasAt(msSolWordsAddress(infoWords), msSolWordsAddress(headerWords), program, metas, count, data, length, signers, signerCount, invoke);
}
