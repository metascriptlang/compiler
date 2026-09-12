// Route 15h: Checker — `Maybe` wrappers over two instances of one generic are two types

import { strictErrorCount, hasError } from "./helpers";

const NEEDS = "function needsStr(s: string): string { return s; }\nfunction needsNum(n: number): number { return n; }\n";
const ACC = "type Acc<T> = distinct (() => T);\ninterface Q { a?: Acc<number> | null; b?: Acc<string> | null; }\n";
const ALIAS = "type Th<T> = () => T;\ninterface R { a?: Th<number> | null; b?: Th<string> | null; }\n";

test "two nullable accessor fields keep their own payloads" {
	assert strictErrorCount(ACC + NEEDS + "function f(q: Q): string { if (q.b != null) { return q.b; } return \"n\"; }\nfunction g(q: Q): number { if (q.a != null) { return q.a + 1; } return 0; }") == 0;
	assert hasError(ACC + NEEDS + "function f(q: Q): number { if (q.b != null) { return needsNum(q.b); } return 0; }", "got string, expected number");
}

test "two nullable alias-instance fields keep their own payloads" {
	assert strictErrorCount(ALIAS + NEEDS + "function f(r: R): string { if (r.b != null) { return r.b(); } return \"n\"; }\nfunction g(r: R): number { if (r.a != null) { return r.a() + 1; } return 0; }") == 0;
}
