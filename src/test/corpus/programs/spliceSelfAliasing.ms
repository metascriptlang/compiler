// @stdout: splice-self-alias all-ok
class SpliceLeaf { label: string; constructor(label: string) { this.label = label; } }


function runSelfAliasing(): void {
	const strings: string[] = ["self-".repeat(8)];
	const refs: SpliceLeaf[] = [new SpliceLeaf("live")];
	for (let i = 0; i < 40; i += 1) {
		strings.splice(0, 1, strings[0]);
		refs.splice(0, 1, refs[0]);
	}
	if (strings.length != 1 || strings[0] != "self-".repeat(8)) process.exit(1);
	if (refs.length != 1 || refs[0].label != "live") process.exit(1);
}
runSelfAliasing();
console.log("splice-self-alias all-ok");
