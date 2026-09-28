import {
	ArbitrumError, Word, StorageKey,
	calldata, selector, requireArguments, uint64At,
	fromUint64, toUint64, toWord, slot, load, store,
	msgSender, nonPayable, finish,
} from "std/arbitrum";
import { Counter, increment } from "./rules";

function execute(): Result<Word, ArbitrumError> {
	const _value = try nonPayable();
	const input = calldata();
	const method = try input.selector();
	const state = StorageKey.slot(0);
	return match (method) {
		0x6d4ce63c => {
			const _args = try input.requireArguments(0);
			return Result.ok(state.load());
		},
		0xdd9a82bc => {
			const args = try input.requireArguments(1);
			const amount = try args.uint64At(0);
			const current = try state.load().toUint64();
			let counter: Counter = { value: current };
			const changed = counter.increment(amount);
			if (!changed.ok) { return Result.err(ArbitrumError.Rejected); }
			const value = Word.fromUint64(counter.value);
			state.store(value);
			return Result.ok(value);
		},
		0x67e404ce => {
			const _args = try input.requireArguments(0);
			return Result.ok(msgSender().toWord());
		},
		0xbe12ac2e => {
			const args = try input.requireArguments(1);
			const amount = try args.uint64At(0);
			state.store(Word.fromUint64(amount));
			return Result.err(ArbitrumError.Rejected);
		},
		_ => Result.err(ArbitrumError.UnknownSelector),
	};
}

finish(execute());
