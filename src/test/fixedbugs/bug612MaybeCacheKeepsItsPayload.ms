// Symptom: a second compilation in one process that declares `struct Box` again and uses `Box | null` failed with `Type 'Box' is not assignable to type 'Box'` (the LSP and `msc test` compile many times per process).
// Root cause: createMaybeType cached `T | null` by T's name and module path for the life of the process, so the second compilation got the first one's carrier, whose payload is the earlier `Box`.
// Fix: a cached carrier answers only for the same payload symbol; a stale one under the same key is replaced.
import { compileToC } from "../helpers";

test "bug612: the same struct declared again gets its own T | null" {
	const first = compileToC(`
		struct Box { names: string[]; count: int32; }
		interface Slot { got: Box | null; }
		function get(slot: Slot): Box {
			if (slot.got == null) return { names: [], count: 0 };
			return slot.got as Box;
		}
	`);
	assert first.ok, first.ok ? "" : first.error;
	const second = compileToC(`
		struct Box { names: string[]; count: int32; }
		function get(): Box {
			let got: Box | null = null;
			const fill = (): void => { got = { names: ["a"], count: 1 }; };
			fill();
			if (got == null) return { names: [], count: 0 };
			return got!;
		}
	`);
	assert second.ok, second.ok ? "" : second.error;
}

test "bug612: a struct whose fields changed between compilations gets a fresh T | null" {
	const first = compileToC(`
		struct Box { names: string[]; count: int32; }
		function pick(b: Box | null): int32 { return b == null ? 0 : b!.count; }
	`);
	assert first.ok, first.ok ? "" : first.error;
	const second = compileToC(`
		struct Box { total: int64; }
		function pick(b: Box | null): int64 { return b == null ? 0 : b!.total; }
		function wrap(x: Box): Box | null { return x; }
	`);
	assert second.ok, second.ok ? "" : second.error;
}
