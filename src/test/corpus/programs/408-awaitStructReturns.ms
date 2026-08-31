// @maxrss: 40
// @stdout: await-struct-returns acc=1600000
// @serial
// note: FIXED (struct-future layout unification). A struct-valued future had TWO layouts by source and neither read path handled both (isBoxed removed Session 4 → no runtime dispatch). async fn struct return was INLINE (msFutureCreateInline + msFutureCompleteT) while actor CALL + spawn were BOXED (msSinkBoxStruct → void*); await's deferred reader (msWaitFor+msUnboxStruct = BOXED) crashed on the async INLINE layout. Fix chose BOXED as the one representation (matching the AwaitGroup void** primitive + the majority): asyncBridge now boxes async struct/tuple/generic-instance returns via msSinkBoxStruct — exactly the path arrays already used — so await's existing boxed reader handles EVERY source uniformly; String stays inline (msFutureCreateInline + msFutureReadString typed reader — a 16-byte value with a working typed path, excluded from the box). lowerWaitFor mirrors: only String → msWaitForStruct, struct/tuple/GI → boxed unbox (this also fixed a pre-existing waitFor-on-actor-struct garbage read). Zero change to the await reader, actor reply completion, AwaitGroup, or any locked cross-thread protocol. Struct carries a HEAP field (tag: string) so the fix is proven to transfer the string's DRC ownership through the box (msSinkBoxStruct memcpy+memset-move → msUnboxStruct copy-out+free-shell), not just copy POD. Paired with await-struct-actorspawn (regression guard for the actor/spawn boxed path).

struct Msg { tag: string; n: number; }

async function amsg(): Promise<Msg> { let m: Msg = { tag: "async-tag", n: 7 }; return m; }

function run(): void {
	let acc = 0;
	let i = 0;
	while (i < 100000) {
		const q = await amsg();
		acc = acc + q.n + q.tag.length;
		i = i + 1;
	}
	console.log("await-struct-returns acc=" + acc.toString());
}

run();
