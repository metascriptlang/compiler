// A sink parameter is not a sole-owner proof for a move into an actor call
//
// INVARIANT (PARALOCK E148): a call may pass a copy into a `sink` parameter, and a copy of a struct
//   holding a class shares that class with the caller, so `move p` of a sink parameter is refused
//   like any parameter, and the diagnostic names Isolated<T> as the spelling that forwards it
//   (isolatedForwardRuns.ms). A plain borrowed parameter is refused too.
//
// RED MEANS: checkMoveSoleOwner accepts a sink parameter, or stopped naming Isolated<T> for one.
//
// GUARD-CHECK-FAIL a sink parameter does not prove it is the only owner
// GUARD-CHECK-FAIL it is a parameter, so the caller still owns it

class Cell { items: int32[] = []; }
struct Request { name: string; args: Cell; }

actor Worker {
	seen: int32 = 0;
	execute(request: Request): int32 { return this.seen + request.args.items.length as int32; }
}

async function viaSink(worker: Worker, sink request: Request): Promise<int32> {
	return await worker.execute(move request); // GUARD-REFUSED
}

async function viaBorrow(worker: Worker, request: Request): Promise<int32> {
	return await worker.execute(move request); // GUARD-REFUSED
}
