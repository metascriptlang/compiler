// @exit: 1
// @stdout: before native
// @skip-js: node exits 1 with the same "invalid object conversion: DomNode is not NativeNode" line but wraps it in its own uncaught-error report, and parity compares merged stdout+stderr (sibling of 826)
// @xfail(danger): --danger drops the forced conversion check, so the wrong downcast reads the other class's memory instead of stopping
// @xfail(raiser): the Raiser VM does not check object conversions

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
