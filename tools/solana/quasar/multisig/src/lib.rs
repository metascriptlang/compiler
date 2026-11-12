#![no_std]
use quasar_lang::prelude::*;

declare_id!("44444444444444444444444444444444444444444444");

pub const MAX_SIGNERS: usize = 10;

#[derive(Seeds)]
#[seeds(b"vault", config: Address)]
pub struct MultisigVaultPda;

#[program]
mod multisig_quasar {
    use super::*;

    #[instruction(discriminator = [0x18, 0x1e, 0xc8, 0x28, 0x05, 0x1c, 0x07, 0x77])]
    pub fn create(ctx: CtxWithRemaining<Create>, threshold: u8) -> Result<(), ProgramError> {
        let signers = ctx.remaining_accounts().parse::<Signer, MAX_SIGNERS>()?;
        let mut addrs = [Address::new_from_array([0u8; 32]); MAX_SIGNERS];
        let mut count = 0usize;
        for s in signers.iter() {
            addrs[count] = *s.address();
            count += 1;
        }
        let c = &mut ctx.accounts.config;
        if threshold == 0 || threshold as usize > count {
            return Err(ProgramError::Custom(6000));
        }
        c.creator = *ctx.accounts.creator.address();
        c.threshold = threshold;
        c.bump = ctx.bumps.config;
        c.signers.set_from_slice(&addrs[..count]);
        c.label.truncate(0);
        Ok(())
    }

    #[instruction(discriminator = [0xf2, 0x23, 0xc6, 0x89, 0x52, 0xe1, 0xf2, 0xb6])]
    pub fn deposit(ctx: Ctx<Deposit>, amount: u64) -> Result<(), ProgramError> {
        let a = &ctx.accounts;
        a.system_program.transfer(&a.depositor, &a.vault, amount).invoke()
    }

    #[instruction(discriminator = [0x49, 0xed, 0x73, 0x74, 0xff, 0xdb, 0x09, 0x11])]
    pub fn set_label(ctx: Ctx<SetLabel>, label_len: u8, label: [u8; 32]) -> Result<(), ProgramError> {
        let len = label_len as usize;
        if len > 32 {
            return Err(ProgramError::Custom(6003));
        }
        if core::str::from_utf8(&label[..len]).is_err() {
            return Err(ProgramError::Custom(6003));
        }
        let c = &mut ctx.accounts.config;
        c.label.set_from_slice(&label[..len]);
        Ok(())
    }

    #[instruction(discriminator = [0xe9, 0x7e, 0xa0, 0xb8, 0xeb, 0xce, 0x1f, 0x77])]
    pub fn execute_transfer(ctx: CtxWithRemaining<ExecuteTransfer>, amount: u64) -> Result<(), ProgramError> {
        let signers = ctx.remaining_accounts().parse::<Signer, MAX_SIGNERS>()?;
        let a = &ctx.accounts;
        let threshold = a.config.threshold as u32;
        let mut approvals = 0u32;
        for s in signers.iter() {
            for stored in a.config.signers.as_slice() {
                if quasar_lang::keys_eq(s.address(), stored) {
                    approvals += 1;
                    break;
                }
            }
        }
        if approvals < threshold {
            return Err(ProgramError::Custom(6002));
        }
        let signer = a.vault_signer(&ctx.bumps);
        a.system_program.transfer(&a.vault, &a.recipient, amount).invoke_signed(&signer)
    }
}

#[derive(Accounts)]
pub struct Create {
    #[account(mut)]
    pub creator: Signer,
    #[account(init, payer = creator, address = MultisigConfig::seeds(creator.address()))]
    pub config: Account<MultisigConfig>,
    pub system_program: Program<SystemProgram>,
}

#[derive(Accounts)]
pub struct Deposit {
    #[account(mut)]
    pub depositor: Signer,
    pub config: Account<MultisigConfig>,
    #[account(mut, address = MultisigVaultPda::seeds(config.address()))]
    pub vault: UncheckedAccount,
    pub system_program: Program<SystemProgram>,
}

#[derive(Accounts)]
pub struct SetLabel {
    #[account(mut)]
    pub creator: Signer,
    #[account(mut, has_one(creator), address = MultisigConfig::seeds(creator.address()))]
    pub config: Account<MultisigConfig>,
}

#[derive(Accounts)]
pub struct ExecuteTransfer {
    #[account(has_one(creator), address = MultisigConfig::seeds(creator.address()))]
    pub config: Account<MultisigConfig>,
    pub creator: UncheckedAccount,
    #[account(mut, address = MultisigVaultPda::seeds(config.address()))]
    pub vault: UncheckedAccount,
    #[account(mut)]
    pub recipient: UncheckedAccount,
    pub system_program: Program<SystemProgram>,
}

#[account(discriminator = [0x2c, 0x3e, 0xac, 0xe1, 0xf6, 0x03, 0xb2, 0x21], fixed_capacity)]
#[seeds(b"multisig", creator: Address)]
pub struct MultisigConfig {
    pub creator: Address,
    pub threshold: u8,
    pub bump: u8,
    pub label: Vec<u8, 32>,
    pub signers: Vec<Address, 10>,
}
