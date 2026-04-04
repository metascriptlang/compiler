// Supervisor — Erlang OTP supervision tree (MetaScript implementation)
//
// Supervisors monitor child actors and restart them on failure.
// Three restart strategies from Erlang OTP, proven over 30 years.
//
// Usage:
//   import { Supervisor, RestartStrategy, RestartType } from "std/actor/supervisor";

import { ExitReason, stop, link, clockMs } from "std/actor";

export enum RestartStrategy {
	OneForOne,    // only crashed child restarts
	OneForAll,    // all children restart when one crashes
	RestForOne,   // crashed child + all children started after it restart
}

export enum RestartType {
	Permanent,    // always restart (any exit reason)
	Transient,    // restart only on abnormal exit (not Normal)
	Temporary,    // never restart
}

export interface ChildSpec {
	name: string;
	start: () => int64;       // factory function — creates actor, returns pid
	restart: RestartType;
}

export actor Supervisor {
	private strategy: RestartStrategy;
	private maxRestarts: number;
	private maxSeconds: number;
	private specs: ChildSpec[];
	private pids: int64[];
	private restartTimes: number[];

	constructor(strategy: RestartStrategy, maxRestarts: number, maxSeconds: number) {
		this.strategy = strategy;
		this.maxRestarts = maxRestarts;
		this.maxSeconds = maxSeconds;
		this.specs = [];
		this.pids = [];
		this.restartTimes = [];
	}

	addChild(spec: ChildSpec): void {
		this.specs.push(spec);
	}

	start(): void {
		for (let i = 0; i < this.specs.length; i = i + 1) {
			const pid = this.specs[i].start();
			this.pids.push(pid);
			link(this.pid, pid);
		}
	}

	// System message handler: receives EXIT from linked children (auto trap_exits)
	onExit(childPid: int64, reason: ExitReason): void {
		const childIdx = this.findChild(childPid);
		if (childIdx < 0) return;

		// Erlang do_restart parity: check restart type vs reason
		const shouldRestart = match (this.specs[childIdx].restart) {
			RestartType.Permanent => true,
			RestartType.Transient => reason !== ExitReason.Normal,
			RestartType.Temporary => false,
		};

		if (!shouldRestart) return;

		// Erlang add_restart parity: sliding window tolerance
		if (!this.checkTolerance()) {
			console.log("supervisor: max restart intensity reached, shutting down");
			stop(this.pid, ExitReason.Abnormal);
			return;
		}

		// Apply restart strategy
		match (this.strategy) {
			RestartStrategy.OneForOne => {
				const newPid = this.specs[childIdx].start();
				this.pids[childIdx] = newPid;
				link(this.pid, newPid);
			},
			RestartStrategy.OneForAll => { this.restartAll(); },
			RestartStrategy.RestForOne => { this.restartFrom(childIdx); },
		};
	}

	// Erlang add_restart algorithm: sliding window of restart timestamps
	private checkTolerance(): boolean {
		const now = clockMs();
		const threshold = now - (this.maxSeconds * 1000);
		// Prune timestamps older than the period
		const recent: number[] = [];
		for (const t of this.restartTimes) {
			if (t >= threshold) recent.push(t);
		}
		recent.push(now);
		this.restartTimes = recent;
		return recent.length <= this.maxRestarts;
	}

	// Find child index by pid (-1 if not found)
	private findChild(childPid: int64): number {
		for (let i = 0; i < this.pids.length; i = i + 1) {
			if (this.pids[i] === childPid) return i;
		}
		return -1;
	}

	// Stop children in reverse order from endIdx-1 down to startIdx (Erlang: terminate_children)
	private stopChildrenFrom(startIdx: number): void {
		let i = this.pids.length;
		while (i > startIdx) {
			i = i - 1;
			stop(this.pids[i], ExitReason.Killed);
		}
	}

	// Restart children from startIdx onward in forward order
	private restartChildrenFrom(startIdx: number): void {
		for (let j = startIdx; j < this.specs.length; j = j + 1) {
			const newPid = this.specs[j].start();
			this.pids[j] = newPid;
			link(this.pid, newPid);
		}
	}

	private restartAll(): void {
		this.stopChildrenFrom(0);
		this.restartChildrenFrom(0);
	}

	private restartFrom(idx: number): void {
		this.stopChildrenFrom(idx);
		this.restartChildrenFrom(idx);
	}

	onTerminate(reason: ExitReason): void {
		this.stopChildrenFrom(0);
	}
}
