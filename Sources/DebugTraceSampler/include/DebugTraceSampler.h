#ifndef DEBUGTRACE_SAMPLER_H
#define DEBUGTRACE_SAMPLER_H

#include <stdint.h>
#include <mach/mach.h>

/// The stack range of a thread, read once before sampling it. Zero when the
/// thread has no pthread (the walk then trusts any non-null frame pointer
/// below 1 GB of the first, which is how far a stack can reach).
typedef struct {
    uint64_t low;
    uint64_t high;
} dt_stack_bounds;

/// Bounds of `thread`'s stack, from its pthread.
dt_stack_bounds dt_stack_bounds_of(thread_act_t thread);

/// Suspends `thread`, copies its pc and return addresses by walking the
/// frame-pointer chain into `out` (leaf first, at most `max`), and resumes it.
/// Nothing between suspend and resume allocates, takes a lock or calls into
/// the Swift runtime: the thread may hold any of those locks. Returns the
/// number of addresses written, or -1 if the thread could not be suspended
/// (it has exited).
int dt_backtrace(thread_act_t thread, dt_stack_bounds bounds, uint64_t *out, int max);

/// Strips pointer-authentication bits from a code address.
uint64_t dt_strip(uint64_t address);

#endif
