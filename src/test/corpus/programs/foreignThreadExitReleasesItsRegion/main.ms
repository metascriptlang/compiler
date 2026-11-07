// @maxrss: 24
// @stdout: threads 2200 ran
// @skip-js: binds the C fixture foreign.c, which calls MS code from threads the runtime did not create
// @skip-raiser: binds the C fixture foreign.c, whose foreign threads have no Raiser host bridge
// note: Each thread the runtime did not start gets its region, root set and handler list released when it exits, also when another thread-specific destructor runs MS code after that release. Before, every such thread kept its region: 2200 threads grew RSS by 116-124 MB on Linux and 1 GB on Windows.
@include("./foreign.h")
@compile("./foreign.c")
extern function msTestRunForeignThreads(count: int32): int32;

class Node { label: string = ""; next: Node | null = null; }

@exportName("foreignWork")
export function work(seed: int32): int32 {
	const parts: string[] = [];
	for (let i = 0; i < 40; i++) parts.push(`cell ${seed} ${i}`);
	const head = new Node();
	head.label = parts.join(",");
	head.next = new Node();
	return head.label.length > 0 ? 1 : 0;
}

console.log(`threads ${msTestRunForeignThreads(2200)} ran`);
