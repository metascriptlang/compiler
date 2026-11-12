import { Node, NodeKind, NodeFlag, BinaryExprData, IfStmtData, ConditionalExprData, MemberExprData } from "../ast/node";
import { forEachChild } from "../ast/visitor";

const CONDITIONAL_KINDS = [
	NodeKind.SwitchStmt, NodeKind.MatchExpr, NodeKind.MatchStmt, NodeKind.WhileStmt, NodeKind.DoWhileStmt,
	NodeKind.ForStmt, NodeKind.ForOfStmt, NodeKind.ForInStmt, NodeKind.TryCatchStmt, NodeKind.TryExpr, NodeKind.DeferStmt,
];
const SHORT_CIRCUITS = ["&&", "||", "??", "&&=", "||=", "??="];
const LEAVING_KINDS = [
	NodeKind.ReturnStmt, NodeKind.ThrowStmt, NodeKind.BreakStmt, NodeKind.ContinueStmt,
	NodeKind.AwaitExpr, NodeKind.YieldExpr, NodeKind.MacroInvocation, NodeKind.ForOfStmt,
];

class ExitWalk {
	callMayRaise: (call: Node) => boolean;
	site: (n: Node) => void;
	mayHaveLeft: boolean;
}

function mayLeaveRoutine(n: Node, w: ExitWalk): boolean {
	if (n.kind == NodeKind.CallExpr || n.kind == NodeKind.NewExpr) return w.callMayRaise(n);
	return LEAVING_KINDS.includes(n.kind) || n.flags.has(NodeFlag.UserOp) || n.flags.has(NodeFlag.UserOpStores);
}

function step(n: Node | null, w: ExitWalk, conditional: boolean): void {
	if (n == null) return;
	if (n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr || n.kind == NodeKind.ClassDecl) return;
	if (n.kind == NodeKind.IfStmt) {
		const d = n.data as IfStmtData;
		step(d.condition, w, conditional);
		step(d.consequent, w, true);
		step(d.alternate, w, true);
	} else if (n.kind == NodeKind.ConditionalExpr) {
		const d = n.data as ConditionalExprData;
		step(d.ternaryCondition, w, conditional);
		step(d.ternaryConsequent, w, true);
		step(d.ternaryAlternate, w, true);
	} else if (n.kind == NodeKind.BinaryExpr && SHORT_CIRCUITS.includes((n.data as BinaryExprData).operator)) {
		step((n.data as BinaryExprData).left, w, conditional);
		step((n.data as BinaryExprData).right, w, true);
	} else {
		const optional = n.flags.has(NodeFlag.OptionalLink) || (n.kind == NodeKind.MemberExpr && (n.data as MemberExprData).isOptional);
		const inside = conditional || optional || CONDITIONAL_KINDS.includes(n.kind);
		forEachChild(n, (c: Node): void => step(c, w, inside));
	}
	if (!conditional && !w.mayHaveLeft) w.site(n);
	if (mayLeaveRoutine(n, w)) w.mayHaveLeft = true;
}

export function forEachNodeRunBeforeAnyExit(inOrder: Node[], callMayRaise: (call: Node) => boolean, site: (n: Node) => void): void {
	const w: ExitWalk = { callMayRaise, site, mayHaveLeft: false };
	for (const n of inOrder) step(n, w, false);
}
