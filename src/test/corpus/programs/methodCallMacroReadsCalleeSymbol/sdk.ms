import { IdentifierData, Node, NodeKind, bindSym, createNodeAt } from "std/meta";

export class WriteContext {}
export class ReadContext {}
export struct Query<R> { name: string; }
export struct Live<R> { name: string; rows: Vec<R>; }

export class Client {
	sent: string[] = [];
}

export function sendCall<A>(client: Client, name: string, reducer: (ctx: WriteContext, args: A) => void, args: A): string {
	client.sent.push(name);
	return "sent " + name;
}

export function openLive<A, R>(client: Client, name: string, query: (ctx: ReadContext, args: A) => Query<R>, args: A): Live<R> {
	return { name: name, rows: [] };
}

@comptime function nameOf(fn: Node): Node {
	if (fn.kind !== NodeKind.Identifier) { throw new Error("name the function"); }
	return createNodeAt(NodeKind.StringLiteral, { value: (fn as IdentifierData).name }, fn.location);
}

@comptime function expand(target: Node, client: Node, fn: Node, args: Node): Node {
	return createNodeAt(NodeKind.CallExpr, {
		callee: target, arguments: [client, nameOf(fn), fn, args], isDirectCall: false, resolvedOverloadIdx: -1,
	}, client.location);
}

export macro run(this client: Node, reducer: Node, args: Node): Node {
	return expand(bindSym("sendCall")!, client, reducer, args);
}

export macro live(this client: Node, query: Node, args: Node): Node {
	return expand(bindSym("openLive")!, client, query, args);
}
