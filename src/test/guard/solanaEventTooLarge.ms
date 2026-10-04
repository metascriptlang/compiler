// GUARD-OS solana
// GUARD-CHECK-FAIL solanaEventTooLarge.ms:79:
// GUARD-CHECK-FAIL the event is 1032 bytes with its discriminator, over the 1024 the std buffers
// An event is serialized in a stack buffer of 1024 bytes, so one that does not fit is refused where
// it is written, with its size, instead of overrunning the buffer or taking the heap.
// RED MEANS: emit accepted an event the buffer cannot hold, or lost the error that names it.
import { Pubkey, emit, programId } from "std/solana";

struct Crowd {
	key0: Pubkey;
	key1: Pubkey;
	key2: Pubkey;
	key3: Pubkey;
	key4: Pubkey;
	key5: Pubkey;
	key6: Pubkey;
	key7: Pubkey;
	key8: Pubkey;
	key9: Pubkey;
	key10: Pubkey;
	key11: Pubkey;
	key12: Pubkey;
	key13: Pubkey;
	key14: Pubkey;
	key15: Pubkey;
	key16: Pubkey;
	key17: Pubkey;
	key18: Pubkey;
	key19: Pubkey;
	key20: Pubkey;
	key21: Pubkey;
	key22: Pubkey;
	key23: Pubkey;
	key24: Pubkey;
	key25: Pubkey;
	key26: Pubkey;
	key27: Pubkey;
	key28: Pubkey;
	key29: Pubkey;
	key30: Pubkey;
	key31: Pubkey;
}

function main(): void {
	const crowd: Crowd = {
		key0: programId(),
		key1: programId(),
		key2: programId(),
		key3: programId(),
		key4: programId(),
		key5: programId(),
		key6: programId(),
		key7: programId(),
		key8: programId(),
		key9: programId(),
		key10: programId(),
		key11: programId(),
		key12: programId(),
		key13: programId(),
		key14: programId(),
		key15: programId(),
		key16: programId(),
		key17: programId(),
		key18: programId(),
		key19: programId(),
		key20: programId(),
		key21: programId(),
		key22: programId(),
		key23: programId(),
		key24: programId(),
		key25: programId(),
		key26: programId(),
		key27: programId(),
		key28: programId(),
		key29: programId(),
		key30: programId(),
		key31: programId(),
	};
	emit<Crowd>(crowd);
}
main();
