import { accounts, logU64, securityTxt, Writable } from "std/solana";

securityTxt({
	policy: "say \"hi\"\\ done\nline two é1 ✓ ??/ \n7",
	name: "Hibernal",
	sourceCode: "https://github.com/example/hibernal",
	contacts: "email:security@hibernal.example,link:https://hibernal.example/security",
	projectUrl: "https://hibernal.example",
	preferredLanguages: "en,vi",
	encryption: "-----BEGIN PGP PUBLIC KEY BLOCK-----\nabc\n-----END PGP PUBLIC KEY BLOCK-----\n",
	sourceRevision: "0123456789abcdef0123456789abcdef01234567",
	sourceRelease: "v1.0.0",
	auditors: "None",
	acknowledgements: "",
	expiry: "2030-01-01",
});

export struct Ledger { payer: Writable; }

function load(): void {
	const view = accounts<Ledger>();
}

function answer(): uint64 {
	return 7;
}

when (!testBuild) {
	logU64(answer());
}

when (testBuild) {
	test "a program that declares securityTxt still runs its code" {
		assert answer() == 7;
	}
}
