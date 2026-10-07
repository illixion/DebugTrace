#include "DebugTraceSampler.h"
#include <pthread.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

uint64_t dt_strip(uint64_t address) {
#if __has_feature(ptrauth_calls)
    address = (uint64_t)ptrauth_strip((void *)address, ptrauth_key_return_address);
#endif
    // A non-arm64e process can still see signed return addresses in frames of
    // the arm64e system libraries; no user address uses the top bits.
    return address & 0x0000FFFFFFFFFFFFULL & ((1ULL << 47) - 1);
}

dt_stack_bounds dt_stack_bounds_of(thread_act_t thread) {
    dt_stack_bounds bounds = {0, 0};
    pthread_t pthread = pthread_from_mach_thread_np(thread);
    if (pthread) {
        uint64_t high = (uint64_t)pthread_get_stackaddr_np(pthread);
        uint64_t size = (uint64_t)pthread_get_stacksize_np(pthread);
        bounds.high = high;
        bounds.low = high > size ? high - size : 0;
    }
    return bounds;
}

int dt_backtrace(thread_act_t thread, dt_stack_bounds bounds, uint64_t *out, int max) {
    if (max <= 0) return 0;
    if (thread_suspend(thread) != KERN_SUCCESS) return -1;
    int count = 0;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        uint64_t pc = dt_strip((uint64_t)arm_thread_state64_get_pc(state));
        uint64_t lr = dt_strip((uint64_t)arm_thread_state64_get_lr(state));
        uint64_t fp = (uint64_t)arm_thread_state64_get_fp(state);
        out[count++] = pc;
        // A leaf function that hasn't pushed a frame yet is only visible
        // through lr; one that has shows the same address again at [fp+8],
        // and the duplicate is dropped below.
        if (count < max && lr) out[count++] = lr;
        uint64_t low = bounds.low, high = bounds.high;
        if (!high) { low = fp; high = fp + (1ULL << 30); }
        while (count < max && fp && (fp & 0xF) == 0 && fp >= low && fp + 16 <= high) {
            uint64_t next = ((uint64_t *)fp)[0];
            uint64_t ret = dt_strip(((uint64_t *)fp)[1]);
            if (!ret) break;
            if (!(count == 2 && ret == lr)) out[count++] = ret;
            if (next <= fp) break;   // stacks grow down: a frame's caller is higher
            fp = next;
        }
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t stateCount = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &stateCount) == KERN_SUCCESS) {
        uint64_t fp = state.__rbp;
        out[count++] = state.__rip;
        uint64_t low = bounds.low, high = bounds.high;
        if (!high) { low = fp; high = fp + (1ULL << 30); }
        while (count < max && fp && (fp & 0xF) == 0 && fp >= low && fp + 16 <= high) {
            uint64_t next = ((uint64_t *)fp)[0];
            uint64_t ret = ((uint64_t *)fp)[1];
            if (!ret) break;
            out[count++] = ret;
            if (next <= fp) break;
            fp = next;
        }
    }
#endif
    thread_resume(thread);
    return count;
}
