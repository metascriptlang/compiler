#![no_std]

use {
    core::{mem::MaybeUninit, ptr::null_mut, slice::from_raw_parts},
    pinocchio::{
        account::AccountView,
        address::{address_eq, Address, PDA_MARKER},
        error::ProgramError,
        no_allocator, nostd_panic_handler,
        syscalls::{sol_curve_validate_point, sol_sha256},
        ProgramResult,
    },
    pinocchio_system::instructions::Transfer,
};

const INSTRUCTION_MISSING: u32 = 100;
const INSTRUCTION_FALLBACK_NOT_FOUND: u32 = 101;
const INSTRUCTION_DID_NOT_DESERIALIZE: u32 = 102;
const CONSTRAINT_MUT: u32 = 2000;
const CONSTRAINT_SEEDS: u32 = 2006;
const CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT: u32 = 2040;
const ACCOUNT_NOT_ENOUGH_KEYS: u32 = 3005;
const INVALID_PROGRAM_ID: u32 = 3008;
const INVALID_PROGRAM_EXECUTABLE: u32 = 3009;
const ACCOUNT_NOT_SIGNER: u32 = 3010;

const DEPOSIT: u64 = u64::from_le_bytes([242, 35, 198, 137, 82, 225, 242, 182]);
const WITHDRAW: u64 = u64::from_le_bytes([183, 18, 70, 156, 148, 109, 161, 34]);

const CURVE25519_EDWARDS: u64 = 0;

no_allocator!();
nostd_panic_handler!();

trait Slots {
    fn count(&self) -> usize;
    unsafe fn view(&self, slot: usize) -> AccountView;
    unsafe fn named_by_another_slot(&self, slot: usize, declared: usize) -> bool;
}

#[cfg(not(feature = "lazy"))]
mod eager {
    use super::*;

    pinocchio::program_entrypoint!(process_instruction);

    struct Parsed<'a>(&'a [AccountView]);

    impl Slots for Parsed<'_> {
        #[inline(always)]
        fn count(&self) -> usize {
            self.0.len()
        }

        #[inline(always)]
        unsafe fn view(&self, slot: usize) -> AccountView {
            *self.0.get_unchecked(slot)
        }

        #[inline(always)]
        unsafe fn named_by_another_slot(&self, slot: usize, declared: usize) -> bool {
            let named = self.0.get_unchecked(slot).account_ptr();
            let mut other = 0;
            while other < declared {
                if other != slot && self.0.get_unchecked(other).account_ptr() == named {
                    return true;
                }
                other += 1;
            }
            while other < self.0.len() {
                if self.0.get_unchecked(other).account_ptr() == named {
                    return true;
                }
                other += 1;
            }
            false
        }
    }

    fn process_instruction(
        program_id: &Address,
        accounts: &mut [AccountView],
        data: &[u8],
    ) -> ProgramResult {
        dispatch(program_id, &Parsed(accounts), data)
    }
}

#[cfg(feature = "lazy")]
mod lazy {
    use {
        super::*,
        pinocchio::entrypoint::lazy::{InstructionContext, MaybeAccount},
    };

    pinocchio::lazy_program_entrypoint!(process_instruction);

    const DECLARED_SLOTS: usize = 3;

    struct Walked {
        views: [MaybeUninit<AccountView>; DECLARED_SLOTS],
        count: usize,
        named_twice: usize,
    }

    impl Slots for Walked {
        #[inline(always)]
        fn count(&self) -> usize {
            self.count
        }

        #[inline(always)]
        unsafe fn view(&self, slot: usize) -> AccountView {
            self.views.get_unchecked(slot).assume_init()
        }

        #[inline(always)]
        unsafe fn named_by_another_slot(&self, slot: usize, _declared: usize) -> bool {
            self.named_twice & (1 << slot) != 0
        }
    }

    #[inline(always)]
    fn process_instruction(mut context: InstructionContext) -> ProgramResult {
        let mut walked = Walked {
            views: [const { MaybeUninit::uninit() }; DECLARED_SLOTS],
            count: context.remaining() as usize,
            named_twice: 0,
        };
        let mut slot = 0;
        while slot < walked.count {
            match unsafe { context.next_account_unchecked() } {
                MaybeAccount::Account(view) => {
                    if slot < DECLARED_SLOTS {
                        walked.views[slot].write(view);
                    }
                }
                MaybeAccount::Duplicated(original) => {
                    let original = original as usize;
                    if original < DECLARED_SLOTS {
                        walked.named_twice |= 1 << original;
                        if slot < DECLARED_SLOTS {
                            walked.named_twice |= 1 << slot;
                            walked.views[slot] = walked.views[original];
                        }
                    }
                }
            }
            slot += 1;
        }
        let data = unsafe { context.instruction_data_unchecked() };
        let program_id = unsafe { context.program_id_unchecked() };
        dispatch(program_id, &walked, data)
    }
}

#[inline(always)]
fn dispatch<S: Slots>(program_id: &Address, slots: &S, data: &[u8]) -> ProgramResult {
    if data.len() < 8 {
        return Err(ProgramError::Custom(INSTRUCTION_MISSING));
    }
    let tag = unsafe { (data.as_ptr() as *const u64).read_unaligned() };
    let args = unsafe { data.get_unchecked(8..) };
    if tag == DEPOSIT {
        return deposit(program_id, slots, args);
    }
    if tag == WITHDRAW {
        return withdraw(program_id, slots, args);
    }
    Err(ProgramError::Custom(INSTRUCTION_FALLBACK_NOT_FOUND))
}

#[inline(always)]
fn amount_of(args: &[u8]) -> Result<u64, ProgramError> {
    if args.len() < 8 {
        return Err(ProgramError::Custom(INSTRUCTION_DID_NOT_DESERIALIZE));
    }
    Ok(unsafe { (args.as_ptr() as *const u64).read_unaligned() })
}

#[inline(always)]
fn writable_signer<S: Slots>(
    slots: &S,
    slot: usize,
    declared: usize,
    account: &AccountView,
) -> ProgramResult {
    if !account.is_signer() {
        return Err(ProgramError::Custom(ACCOUNT_NOT_SIGNER));
    }
    writable(slots, slot, declared, account)
}

#[inline(always)]
fn writable<S: Slots>(
    slots: &S,
    slot: usize,
    declared: usize,
    account: &AccountView,
) -> ProgramResult {
    if unsafe { slots.named_by_another_slot(slot, declared) } {
        return Err(ProgramError::Custom(CONSTRAINT_DUPLICATE_MUTABLE_ACCOUNT));
    }
    if !account.is_writable() {
        return Err(ProgramError::Custom(CONSTRAINT_MUT));
    }
    Ok(())
}

#[inline(always)]
fn system_program(account: &AccountView) -> ProgramResult {
    if !address_eq(account.address(), &pinocchio_system::ID) {
        return Err(ProgramError::Custom(INVALID_PROGRAM_ID));
    }
    if !account.executable() {
        return Err(ProgramError::Custom(INVALID_PROGRAM_EXECUTABLE));
    }
    Ok(())
}

#[inline(always)]
fn canonical_vault(program_id: &Address, user: &Address, vault: &Address) -> ProgramResult {
    let mut bump = [u8::MAX];
    let bump_at = bump.as_mut_ptr();
    let preimage: [&[u8]; 5] = [
        b"vault",
        user.as_ref(),
        unsafe { from_raw_parts(bump_at, 1) },
        program_id.as_ref(),
        PDA_MARKER,
    ];
    let mut hash = MaybeUninit::<Address>::uninit();
    let mut candidate = u8::MAX;
    while candidate > 0 {
        unsafe {
            bump_at.write(candidate);
            sol_sha256(
                preimage.as_ptr() as *const u8,
                preimage.len() as u64,
                hash.as_mut_ptr() as *mut u8,
            );
            let off_curve =
                sol_curve_validate_point(CURVE25519_EDWARDS, hash.as_ptr() as *const u8, null_mut())
                    != 0;
            if off_curve {
                if !address_eq(hash.assume_init_ref(), vault) {
                    return Err(ProgramError::Custom(CONSTRAINT_SEEDS));
                }
                return Ok(());
            }
        }
        candidate -= 1;
    }
    Err(ProgramError::InvalidSeeds)
}

#[inline(always)]
fn deposit<S: Slots>(program_id: &Address, slots: &S, args: &[u8]) -> ProgramResult {
    let amount = amount_of(args)?;
    if slots.count() < 3 {
        return Err(ProgramError::Custom(ACCOUNT_NOT_ENOUGH_KEYS));
    }
    let (user, vault, program) = unsafe { (slots.view(0), slots.view(1), slots.view(2)) };
    writable_signer(slots, 0, 3, &user)?;
    writable(slots, 1, 3, &vault)?;
    system_program(&program)?;
    canonical_vault(program_id, user.address(), vault.address())?;
    Transfer {
        from: &user,
        to: &vault,
        lamports: amount,
    }
    .invoke()
}

#[inline(always)]
fn withdraw<S: Slots>(program_id: &Address, slots: &S, args: &[u8]) -> ProgramResult {
    let amount = amount_of(args)?;
    if slots.count() < 2 {
        return Err(ProgramError::Custom(ACCOUNT_NOT_ENOUGH_KEYS));
    }
    let (mut user, mut vault) = unsafe { (slots.view(0), slots.view(1)) };
    writable_signer(slots, 0, 2, &user)?;
    writable(slots, 1, 2, &vault)?;
    canonical_vault(program_id, user.address(), vault.address())?;
    vault.set_lamports(vault.lamports() - amount);
    user.set_lamports(user.lamports() + amount);
    Ok(())
}
