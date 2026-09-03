// nim-guard: the four boundary verbs must keep rejecting the shapes they exist for
//
// INVARIANT (PARALOCK Amendment I, I21/I22): a value crossing an actor boundary
//   is a COPY, a MOVE, a BORROW (lender provably outlives the use) or a SHARE
//   (Arc<T>, atomic rc, incref at the msgSetter). Four compile-time rules carry
//   that model, and each one closes a MEASURED hole:
//     1. SEND-class plain ref (void method / discarded result) — the sender
//        never parks, so its scope-exit decref frees the cell while the message
//        is in flight. Measured pre-fix as a deterministic use-after-free
//        (2000 SENDs read the reuser's field: rounds × junk.n, 5/5 runs).
//     2. Discarded CALL — reply-bearing, but nothing awaits it, so the BORROW
//        has no park behind it: same hole, reached through the other class.
//     3. Arc pointee must be deep-immutable — SHARE aliases the pointee across
//        threads, so a Ref or an array inside it re-introduces shared mutable
//        state (and, for a lock, the mixed-rc two-cell shape this amendment
//        supersedes: atomic handle, non-atomic inner refcount).
//     4. Write through an Arc handle — the same immutability, enforced at the
//        write site instead of the type.
//   And the one rule that keeps the replacement honest:
//     5. Locked<T> payload must own no memory — the payload is stored under the
//        lock by a raw field assignment with no destroy-of-previous, so an
//        owning payload leaks one value per update (I22 landing scope).
//
// WHAT IT CATCHES: any of the five silently dropped by a checker refactor. The
//   runtime half is corpus 415 (Arc→actor SEND + CALL, flat RSS) and 405 (a
//   Locked counter under spawn contention) — but a corpus program can only
//   prove that the SOUND shapes still work; nothing there goes red when the
//   compiler starts accepting the unsound ones again. That is this file's job.
//
// RED MEANS: a rule stopped firing (the shape it guards is a race again), or a
//   diagnostic was retagged. Retag only with a PARALOCK amendment.
//
// Proven red 2026-09-03, against a compiler with exactly these five checks
// disabled (the pre-amendment binary cannot be used directly: it predates the
// Locked type and dies in the prelude). Cases 1-4 in isolation BUILD CLEAN on
// it — the four unsound shapes compile and run. Case 5 is weaker by nature: the
// checker also goes silent, but the build then dies at link (the cell's destroy
// hook is undefined for an owning payload), so its red proves the diagnostic is
// what turns a link failure into an explained one.
//
// GUARD-CHECK-FAIL fire-and-forget actor call would share a plain reference
// GUARD-CHECK-FAIL discarded actor call borrows a plain reference
// GUARD-CHECK-FAIL pointee must be deep-immutable data
// GUARD-CHECK-FAIL cannot write through 'Arc<T>'
// GUARD-CHECK-FAIL payload must be plain data

interface Plain { n: int32; }

struct Pod { n: int32; }

struct Holder { inner: Plain; }

struct Owner { s: string; }

actor Verbs {
	total: int32 = 0;

	// SEND-class: void, so the sender cannot park on a reply.
	absorb(p: Plain): void { this.total = this.total + p.n; }

	// Reply-bearing: a BORROW only while the sender is parked on the await.
	weigh(p: Plain): int32 { return p.n; }
}

// 1 — SEND-class plain ref: the UAF shape.
function sendClassPlainRef(): void {
	const p: Plain = { n: 1 };
	const v = new Verbs();
	v.absorb(p);
}

// 2 — reply-bearing but discarded: the borrow has no park behind it.
function discardedCallBorrow(): void {
	const p: Plain = { n: 2 };
	const v = new Verbs();
	v.weigh(p);
}

// 3 — SHARE pointee holding a reference.
function arcPointeeNotImmutable(): void {
	const p: Plain = { n: 3 };
	const bad: Arc<Holder> = new Arc({ inner: p });
	console.log(bad.inner.n);
}

// 4 — write reaching through a SHARE handle.
function writeThroughShare(): void {
	const a: Arc<Pod> = new Arc({ n: 4 });
	a.n = 5;
}

// 5 — Locked payload that owns memory (raw store, no destroy-on-store).
function lockedPayloadOwnsMemory(): void {
	const c: Locked<Owner> = new Locked({ s: "leaks-one-per-update" });
	console.log(c);
}

sendClassPlainRef();
discardedCallBorrow();
arcPointeeNotImmutable();
writeThroughShare();
lockedPayloadOwnsMemory();
