// @stdout: down-conv native=native dom=42 base=native null=ok iof=native,other,other mixed=100/300
// @xfail(raiser): the Raiser VM cannot evaluate class inheritance (super) or instanceof at comptime

type HostNode = unknown;

class BaseNode { id: int32 = 0; }
class NativeNode extends BaseNode { view: string = "native"; }
class DomNode extends BaseNode { el: int32 = 42; }
class Other { tag: string = "other"; }

function viewOf(n: HostNode): string {
	return (n as NativeNode).view;
}

function elOf(n: HostNode): int32 {
	return (n as DomNode).el;
}

function viewOfBase(b: BaseNode): string {
	return (b as NativeNode).view;
}

function describe(n: HostNode): string {
	if (n instanceof NativeNode) return n.view;
	if (n instanceof Other) return n.tag;
	return "other";
}

function nullPasses(): string {
	const empty: HostNode | null = null;
	const n = empty as NativeNode | null;
	return n == null ? "ok" : "bad";
}

function mixed(): string {
	const nodes: HostNode[] = [];
	let natives = 0 as int32;
	for (let i = 0; i < 300; i += 1) {
		if (i % 3 == 0) nodes.push(new NativeNode());
		else if (i % 3 == 1) nodes.push(new DomNode());
		else nodes.push(new Other());
	}
	for (const n of nodes) {
		if (n instanceof NativeNode) natives += 1;
	}
	return `${natives}/${nodes.length}`;
}

function main(): void {
	const a: HostNode = new NativeNode();
	const b: HostNode = new DomNode();
	const c: BaseNode = new NativeNode();
	const iof = [describe(new NativeNode()), describe(new Other()), describe(new DomNode())].join(",");
	console.log(`down-conv native=${viewOf(a)} dom=${elOf(b)} base=${viewOfBase(c)} null=${nullPasses()} iof=${iof} mixed=${mixed()}`);
}
main();
