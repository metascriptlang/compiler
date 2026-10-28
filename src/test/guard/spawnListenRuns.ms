// An HTTP server may listen inside a spawn: the signal-listener removal only compares a function value
//
// INVARIANT (ULTRALOCK module state; the reference's gcsafe call rule): passing a function value to a
//   routine that only compares it by identity runs nothing, so a spawn that reaches
//   `AbortSignal.removeEventListener` through `server.listen` stays Sendable-clean. A function value the
//   callee calls or stores is still refused (spawnOpaqueFunctionRejects.ms).
//
// RED MEANS: effects.ms counts an identity comparison of a function parameter as passing a function value.

import { AsyncRequestHandler, HttpRequest, ServerResponse, createServerAsync, stop } from "std/http";

function serve(port: int32): int32 {
	const handler: AsyncRequestHandler = async (req: HttpRequest, res: ServerResponse): Promise<void> => {};
	const server = createServerAsync(handler);
	const bound = server.listen("127.0.0.1", port);
	if (!bound.ok) return 1;
	stop(server);
	return 0;
}

const a = await spawn(() => serve(18761));
const b = await spawn(() => serve(18762));
if (a != 0 || b != 0) throw new Error(`a=${a} b=${b}`);
console.log("GUARD-OK");
