// @exit: 1
// @stdout: before native
// @xfail(danger): --danger drops the forced conversion check, so the wrong downcast reads the other class's memory instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid object conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output

type HostNode = unknown;

class BaseNode { id: int32 = 0; }
class NativeNode extends BaseNode { view: string = "native"; }
class DomNode extends BaseNode { el: int32 = 42; }

function viewOf(n: HostNode): string {
	return (n as NativeNode).view;
}

function main(): void {
	console.log(`before ${viewOf(new NativeNode())}`);
	console.log(`after ${viewOf(new DomNode())}`);
}
main();
