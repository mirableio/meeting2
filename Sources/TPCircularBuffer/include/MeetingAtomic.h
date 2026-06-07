#ifndef MeetingAtomic_h
#define MeetingAtomic_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Project-local realtime counters used by Swift callback contexts. They live in
// the C target because Swift has no standard-library atomic integer, and the
// Core Audio IOProc must not take locks or touch Swift reference-counted state.
uint64_t MeetingAtomicUInt64Load(const uint64_t *value);
void MeetingAtomicUInt64Store(uint64_t *value, uint64_t desired);
bool MeetingAtomicUInt64CompareExchange(uint64_t *value, uint64_t expected, uint64_t desired);
uint64_t MeetingAtomicUInt64FetchAdd(uint64_t *value, uint64_t amount);

#ifdef __cplusplus
}
#endif

#endif
