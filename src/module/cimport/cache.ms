// cparse — HeaderCache actor: deduplicated #include expansion
//
// Memoizes (path, target, defines) → preprocessed tokens so the same system
// header (stdio.h, stdint.h) is tokenized once per binding session regardless
// of how many consumers transitively #include it.
//
// Actor isolation gives us a lock-free, race-free map: many parse workers
// can hit get() concurrently via the mailbox.
//
// STATUS: skeleton. Will be populated alongside task #15 (preprocess port)
// so the #include handler can hit this cache.

import { CToken } from "../cparse/token";
import { TargetInfo } from "../cparse/target";

export interface CachedTokens {
	head: CToken;
	sourceHash: string;   // hash of file bytes — key component
	target: string;       // triple name — key component
	definesKey: string;   // canonicalized -D flags — key component
}

// Build the cache key. Same file under two different -D sets = two entries.
export function makeCacheKey(path: string, target: TargetInfo, defines: string[]): string {
	const sorted: string[] = [...defines];
	sorted.sort((a, b) => a < b ? -1 : (a > b ? 1 : 0));
	return `${path}|${target.tripleName}|${sorted.join(",")}`;
}

export actor HeaderCache {
	private entries: HashMap<string, CachedTokens> = new HashMap<string, CachedTokens>();
	private hits: number = 0;
	private misses: number = 0;

	// CALL — returns null on miss; caller is responsible for populating.
	// We split lookup/insert so the preprocessor can decide whether to offload
	// the cold-miss tokenize+preprocess to a spawn (keeps the actor mailbox
	// responsive).
	lookup(key: string): CachedTokens {
		const hit = this.entries.get(key);
		if (hit !== null) {
			this.hits = this.hits + 1;
			return hit;
		}
		this.misses = this.misses + 1;
		return null as unknown as CachedTokens;
	}

	// SEND — fire-and-forget insert. Safe because CachedTokens is immutable
	// after construction and keys are deterministic.
	insert(key: string, tokens: CachedTokens): void {
		this.entries.set(key, tokens);
	}

	// CALL — stats for tests.
	stats(): number[] {
		return [this.hits, this.misses, this.entries.size];
	}

	// SEND — invalidate on file change (used by LSP integration later).
	clear(): void {
		this.entries = new HashMap<string, CachedTokens>();
		this.hits = 0;
		this.misses = 0;
	}
}
