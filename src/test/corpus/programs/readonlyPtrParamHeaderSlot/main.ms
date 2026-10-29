// An exported function whose parameter is a Readonly<Ptr<T>> fills a header function-pointer
// slot declared with `const T*`: the function and the slot's typedef agree on const, so C
// compiles without a discarded-qualifier diagnostic. Axes: a uint8 buffer beside its length
// and a struct.
//
// @xfail(raiser): raiser has no host bridge for the header's C functions 'corpusRunByteSink' and 'corpusRunPairSink', so the externs cannot run in the VM
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 24|5
// @exit: 0

import { corpusRunByteSink, corpusRunPairSink, CorpusPair, size_t } from "./slot.h";

let total = 0;
let pairSum = 0;

export function sumBytes(user: Ptr<void> | null, bytes: Readonly<Ptr<uint8>> | null, n: size_t): void {
	if (bytes === null) return;
	for (const b of bytes[0..n]) total += b;
}

export function sumPair(user: Ptr<void> | null, pair: Readonly<Ptr<CorpusPair>> | null): void {
	if (pair === null) return;
	pairSum = pair.a + pair.d;
}

corpusRunByteSink(sumBytes);
corpusRunPairSink(sumPair);
console.log(`${total}|${pairSum}`);
