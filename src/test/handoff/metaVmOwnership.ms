// Handoff tier: what a macro body can do to the VM heap cells its arguments were marshalled into.
// Pins of today's behaviour that the provenance plan of the node-identity card builds on, not a contract: a change to them is a decision. Siblings: metaFrameThrow.ms, macroExpansionBoundary.ms.
import { compileToCWithStd } from "../helpers";
import { observeComptimeRuns } from "../../compiler/meta/hostPolicy";
import { rcCountOf, heapAllocObject } from "../../raiser/value";
import { RaiserVM, createVM, vmCallFunction, vmReleaseHeaps } from "../../raiser/vm";
import { RaiserOpcode, RaiserInstruction, raiserABC } from "../../raiser/bytecode";
import { createRaiserFunction, createRaiserModule } from "../../raiser/module";
import { raiserConstString, raiserNil } from "../../raiser/value";
import { registerHostFn, HostCapability, _resetHostRegistryForTests, RaiserHostFn } from "../../raiser/hostRegistry";
import { RaiserValue } from "../../raiser/value";

function heapRcs(vm: RaiserVM): string {
	let out = "";
	for (let i = 0; i < vm.objectHeap.objects.length; i = i + 1) out = out + vm.objectHeap.objects[i].rc.toString() + " ";
	return `objects=${vm.objectHeap.objects.length} free=${vm.objectHeap.freeList.length} rc=[${out.trim()}]`;
}

function snapshotOf(body: string): string {
	let seen = "";
	const previous = observeComptimeRuns((vm: RaiserVM, ran: int32[]): void => { seen = heapRcs(vm); });
	const result = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

export macro probe(node: Node): Node {
	${body}
	return node;
}

console.log(probe(1 + 2));
`);
	observeComptimeRuns(previous);
	if (!result.ok) return "compile failed: " + result.error;
	return seen;
}

test "a macro that only reads its argument leaves every marshalled cell live" {
	assert snapshotOf("const l = node.left;") == "objects=6 free=0 rc=[2 1 1 1 1 1]";
}

test "a macro that overwrites a child of its argument drives that cell to count 0 and frees its slot" {
	assert snapshotOf("node.left = node.right;") == "objects=6 free=2 rc=[2 0 0 2 1 1]";
}

test "a nested run on a VM with a floor held keeps the heap until the outer run releases it" {
	_resetHostRegistryForTests();
	const outer: RaiserInstruction[] = [raiserABC(RaiserOpcode.CallHost, 0, 0, 0), raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	const inner: RaiserInstruction[] = [raiserABC(RaiserOpcode.Halt, 0, 0, 0)];
	const fns = [createRaiserFunction("outer", outer, [raiserConstString("floorProbe")], 0, 0, 16), createRaiserFunction("inner", inner, [], 0, 0, 16)];
	const vm = createVM(createRaiserModule("floor", fns, 0));
	let seen = "";
	const probe: RaiserHostFn = (args: RaiserValue[]): RaiserValue => {
		heapAllocObject(vm.objectHeap);
		seen = "before " + heapRcs(vm);
		vmCallFunction(vm, 1, []);
		vmReleaseHeaps(vm);
		seen = seen + " | nested-release " + heapRcs(vm);
		return raiserNil();
	};
	registerHostFn("floorProbe", probe, HostCapability.Pure);
	vmCallFunction(vm, 0, []);
	seen = seen + " | outer-done err='" + vm.error + "'";
	vmReleaseHeaps(vm);
	seen = seen + " | outer-release " + heapRcs(vm);
	_resetHostRegistryForTests();
	assert seen == "before objects=1 free=0 rc=[1] | nested-release objects=1 free=0 rc=[1] | outer-done err='' | outer-release objects=0 free=0 rc=[]", seen;
}
