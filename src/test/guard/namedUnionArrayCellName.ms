// nim-guard: every array cell of a named union is destroyed once, and the ledger
// names the cell by the union's source spelling, never by its module path.
//
// Nim ccgtypes.nim:1756 genTypeInfo2Name builds a runtime type name from module
// names alone, apart from the C symbol; ours keep the pre-qualification spelling
// (ensureTypeInfoDef's runtimeName, types.ms). NIM-REF CG-41 (SAME). Proven red on
// wt/nim-integ 415559bf, where the cells report `NuPod__M<escaped absolute
// path>ArrayRefCell`: no declaration can name them, the path differs per host.
//
// RED MEANS a cell leaked or double-freed, or its runtime name picked up the
// module qualifier again; run /trace-nim on refArrayCellLabel (codegen/c/types.ms)
// for the named cell.
//
// GUARD-BALANCE NuPodArrayRefCell
// GUARD-BALANCE NuTokArrayRefCell
// GUARD-JS

type NuPod = boolean | float64;
type NuTok = string | int32;

class NuBox {
	pods: NuPod[] = [];
	toks: NuTok[] = [];
}

function round(i: int32): int32 {
	const pods: NuPod[] = [1.5, false];
	pods.push(i as float64);
	const toks: NuTok[] = ["t" + i.toString(), i];
	toks.push("u" + i.toString());
	const b = new NuBox();
	b.pods.push(true);
	b.toks.push("f" + i.toString());
	const podCopy = pods.slice(0, pods.length);
	const tokCopy = toks.slice(0, toks.length);
	return (pods.length + toks.length + b.pods.length + b.toks.length + podCopy.length + tokCopy.length) as int32;
}

function main(): void {
	let s: int32 = 0;
	for (let i: int32 = 0; i < 50; i += 1) {
		s = s + round(i);
	}
	console.log(s);
	if (s == 700) console.log("GUARD-OK");
}
main();
