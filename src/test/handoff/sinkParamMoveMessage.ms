import { hasError } from "./helpers";

const SHAPE = `
class Cell { items: int32[] = []; }
struct Request { name: string; args: Cell; }
actor Worker { execute(request: Request): int32 { return 0; } }
`;

test "sinkParamMoveMessage: moving a sink parameter into an actor call names Isolated, a borrowed one does not" {
	const viaSink = SHAPE + "async function f(worker: Worker, sink request: Request): Promise<int32> { return await worker.execute(move request); }";
	assert hasError(viaSink, "a sink parameter does not prove it is the only owner") && hasError(viaSink, "Isolated<T>"), "sink";
	const viaBorrow = SHAPE + "async function f(worker: Worker, request: Request): Promise<int32> { return await worker.execute(move request); }";
	assert hasError(viaBorrow, "it is a parameter, so the caller still owns it") && !hasError(viaBorrow, "sink parameter"), "borrow";
}
