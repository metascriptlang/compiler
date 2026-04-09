// cparse — DiagnosticSink actor: ordered cross-job diagnostic merging
//
// Parallel parse jobs spawn with Promise.all emit diagnostics in
// nondeterministic order. The sink accepts fire-and-forget sends from
// workers and returns deterministically sorted results on flush.

import { Diagnostic, cmpDiag } from "../cparse/error";

export actor DiagnosticSink {
	private diags: Diagnostic[] = [];

	// SEND — fire-and-forget. Parse workers never block reporting errors.
	report(diag: Diagnostic): void {
		this.diags.push(diag);
	}

	// SEND — batch submit (for phase-end dumps).
	reportAll(list: Diagnostic[]): void {
		for (const d of list) this.diags.push(d);
	}

	// CALL — deterministic output. Await once at the end.
	flush(): Diagnostic[] {
		const sorted: Diagnostic[] = [];
		for (const d of this.diags) sorted.push(d);
		sorted.sortBy((a, b) => cmpDiag(a, b));
		this.diags = [];
		return sorted;
	}

	// CALL — snapshot without draining (for tests).
	count(): number {
		return this.diags.length;
	}
}
