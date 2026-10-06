// GUARD-OS solana -d:programId=B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32 -d:programKeypair=src/test/guard/solanaDeployKeypair.json
// GUARD-CHECK-FAIL the build declares programId B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32, but the deploy keypair
// GUARD-CHECK-FAIL is program Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS: set programId to Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS
// The deploy keypair (its public half, bytes 32-63 of the solana-keygen JSON) must hold the declared
// program id, as `anchor keys sync` keeps declare_id! equal to it; the fixture holds another id.
// RED MEANS: a build deploys at one address while its entry checks another, so every call fails 4100.
import { ProgramError, failWith, instruction } from "std/solana";

enum Op { Ping }

function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<Op>()) {
		Op.Ping => Result.ok(0),
	};
}

const result = dispatch();
if (!result.ok) { failWith(result.error); }
