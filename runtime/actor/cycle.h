/*
 * MetaScript Actor Cycle Detector
 *
 * Detects dead actor reference cycles (A→B→A where both are idle).
 * Runs periodically on scheduler 0's poll loop.
 *
 * Simplified Pony ORCA: no separate actor, no message protocol.
 * Direct flag checking (single-threaded on scheduler 0).
 *
 * Algorithm:
 * 1. Iterate all registered actors
 * 2. For each BLOCKED actor, trace its refs
 * 3. If ALL refs point to BLOCKED actors → dead cycle
 * 4. Collect the cycle (msActorDestroy each)
 */

#ifndef MS_ACTOR_CYCLE_H
#define MS_ACTOR_CYCLE_H

#include "actor.h"

/*
 * Run the cycle detector. Called from msActorPollAll every MS_CYCLE_INTERVAL polls.
 * Scans all registered actors for dead cycles and collects them.
 */
static inline void msCycleDetectorRun(void) {
    /* Pass 1: find all BLOCKED actors (exclude SUSPENDED — they're alive, waiting on spawns) */
    int blockedCount = 0;
    for (int i = 0; i < msGlobalActors.count; i++) {
        msActor* a = msGlobalActors.actors[i];
        if (msActorHasFlag(a, MS_ACTOR_BLOCKED) && !msActorHasFlag(a, MS_ACTOR_SUSPENDED)) {
            blockedCount++;
        }
    }
    if (blockedCount < 2) return;  /* Need at least 2 for a cycle */

    /* Pass 2: for each BLOCKED actor, check if ALL its refs are also BLOCKED.
     * If so, this actor is part of a dead cycle candidate. */
    for (int i = 0; i < msGlobalActors.count; i++) {
        msActor* a = msGlobalActors.actors[i];
        if (!msActorHasFlag(a, MS_ACTOR_BLOCKED) || msActorHasFlag(a, MS_ACTOR_SUSPENDED)) continue;
        if (a->refsCount == 0) continue;

        bool allRefsBlocked = true;
        for (int r = 0; r < a->refsCount; r++) {
            if (!msActorHasFlag(a->refs[r], MS_ACTOR_BLOCKED)) {
                allRefsBlocked = false;
                break;
            }
        }

        if (allRefsBlocked) {
            /* This actor's refs are all blocked — mark for collection. */
            msActorSetFlag(a, MS_ACTOR_CYCLE_MARKED);
        }
    }

    /* Pass 3: collect actors marked as cycle members.
     * Iterate backwards to avoid index shifting issues. */
    for (int i = msGlobalActors.count - 1; i >= 0; i--) {
        msActor* a = msGlobalActors.actors[i];
        if (!msActorHasFlag(a, MS_ACTOR_BLOCKED) || !msActorHasFlag(a, MS_ACTOR_CYCLE_MARKED)) continue;

        /* Verify: all refs of this actor are also marked for collection.
         * This prevents collecting actors that reference non-cycle blocked actors. */
        bool confirmedCycle = true;
        for (int r = 0; r < a->refsCount; r++) {
            msActor* ref = a->refs[r];
            if (!(msActorHasFlag(ref, MS_ACTOR_BLOCKED) && msActorHasFlag(ref, MS_ACTOR_CYCLE_MARKED))) {
                confirmedCycle = false;
                break;
            }
        }

        if (confirmedCycle) {
            /* Remove from registry */
            msGlobalActors.actors[i] = msGlobalActors.actors[msGlobalActors.count - 1];
            msGlobalActors.count--;
            /* Destroy the actor */
            msActorDestroy(a);
        } else {
            /* Not a confirmed cycle — clear the temporary MUTED flag */
            msActorClearFlag(a, MS_ACTOR_CYCLE_MARKED);
        }
    }
}

#endif /* MS_ACTOR_CYCLE_H */
