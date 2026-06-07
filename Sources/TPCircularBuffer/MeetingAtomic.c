#include "MeetingAtomic.h"

// These wrappers deliberately use relaxed ordering: the counters are telemetry,
// not synchronization barriers. The IOProc only needs atomicity, and adding
// stronger ordering would spend realtime budget without protecting extra state.
uint64_t MeetingAtomicUInt64Load(const uint64_t *value) {
    return __atomic_load_n(value, __ATOMIC_RELAXED);
}

void MeetingAtomicUInt64Store(uint64_t *value, uint64_t desired) {
    __atomic_store_n(value, desired, __ATOMIC_RELAXED);
}

bool MeetingAtomicUInt64CompareExchange(uint64_t *value, uint64_t expected, uint64_t desired) {
    return __atomic_compare_exchange_n(
        value,
        &expected,
        desired,
        false,
        __ATOMIC_RELAXED,
        __ATOMIC_RELAXED
    );
}

uint64_t MeetingAtomicUInt64FetchAdd(uint64_t *value, uint64_t amount) {
    return __atomic_fetch_add(value, amount, __ATOMIC_RELAXED);
}
