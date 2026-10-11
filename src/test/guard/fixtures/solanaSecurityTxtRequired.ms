import { logU64, securityTxt } from "std/solana";

securityTxt({ name: "Bare", projectUrl: "https://bare.example", contacts: "email:a@bare.example", policy: "none" });

logU64(1);
