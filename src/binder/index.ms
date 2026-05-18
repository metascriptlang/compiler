// src/binder/index.ms — hub re-exports for the flow graph binder.
//
// The binder constructs a Control Flow Graph by walking the AST after parse
// and before type check. Each reference expression (Identifier, MemberExpr,
// ArrayAccess) gets a `flowNode` attached, which the checker queries via
// src/checker/flow.ms to compute narrowed types at each program point.

export { bindFlowGraph, BinderState } from "./binder";
