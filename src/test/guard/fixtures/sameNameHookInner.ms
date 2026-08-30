// Shared RC-managed payload for the sameNameTypeHooks guard: both same-named
// `Item` declarations hold one of these, so the ledger balance for `Inner` is
// what proves each module's destroy hook actually ran.
export class Inner {
	v: number;
}
