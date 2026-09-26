#include "soc_health.h"

void soc_health_init(soc_health_core_t *core)
{
    uint32_t i;
    static const uint8_t evidence[SOC_IP_COUNT] = {
        SOC_EV_STRONG_PROGRESS, SOC_EV_STRONG_PROGRESS, SOC_EV_PHYSICAL_LOOPBACK,
        SOC_EV_PHYSICAL_LOOPBACK, SOC_EV_STRONG_PROGRESS, SOC_EV_STRONG_PROGRESS,
        SOC_EV_FUNCTIONAL_CONSISTENCY, SOC_EV_STRONG_PROGRESS,
        SOC_EV_INPUT_OBSERVATION, SOC_EV_REGISTER_READBACK,
        SOC_EV_REGISTER_READBACK, SOC_EV_EXCLUDED
    };
    core->epoch = core->publication_id = core->sticky_fail_mask = 0u;
    core->next_slot = core->publication_backlog = 0u;
    for (i = 0u; i < 2u; i++) {
        core->slot[i].readers = 0u;
        core->observer_miss_count[i] = core->observer_last_epoch[i] = 0u;
    }
    for (i = 0u; i < SOC_IP_COUNT; i++) {
        soc_ip_health_t *record = &core->ip[i];
        record->state = SOC_HB_UNKNOWN;
        record->evidence = evidence[i];
        record->heartbeat_count = record->last_progress_epoch = 0u;
        record->miss_count = 0u;
        record->detail = SOC_HEALTH_NOT_IMPLEMENTED;
        core->progress_token[i] = core->miss_token[i] = 0u;
        core->progress_seen[i] = core->miss_seen[i] = 0u;
    }
    core->ip[SOC_IP_AES_GCM].state = SOC_HB_EXCLUDED;
    core->ip[SOC_IP_AES_GCM].detail = SOC_HEALTH_AES_PENDING;
}

static int fresh_token(uint32_t token, uint32_t previous, uint8_t seen)
{
    uint32_t delta = token - previous;
    return !seen || (delta != 0u && delta < 0x80000000u);
}

int soc_health_report(soc_health_core_t *core, soc_ip_id_t id,
                      soc_health_step_t step, uint32_t token, uint32_t detail)
{
    soc_ip_health_t *record;
    if ((uint32_t)id >= SOC_IP_COUNT || id == SOC_IP_AES_GCM ||
        (uint32_t)step > SOC_STEP_DEADLINE_MISS)
        return 0;
    record = &core->ip[id];
    if (step == SOC_STEP_PROGRESS) {
        if (!fresh_token(token, core->progress_token[id], core->progress_seen[id]))
            return 0;
        core->progress_token[id] = token;
        core->progress_seen[id] = 1u;
        record->heartbeat_count++;
        record->last_progress_epoch = core->epoch;
        record->state = SOC_HB_PASS;
    } else if (step == SOC_STEP_DEADLINE_MISS) {
        if (!fresh_token(token, core->miss_token[id], core->miss_seen[id]))
            return 0;
        core->miss_token[id] = token;
        core->miss_seen[id] = 1u;
        record->miss_count++;
        record->state = SOC_HB_FAIL;
    } else if (step == SOC_STEP_FAIL) {
        record->state = SOC_HB_FAIL;
    } else if (step == SOC_STEP_WARN) {
        record->state = SOC_HB_WARN;
    } /* PENDING records detail only: no state/progress/miss invention. */
    record->detail = detail;
    if (record->state == SOC_HB_FAIL)
        core->sticky_fail_mask |= 1u << (uint32_t)id;
    return 1;
}

void soc_health_epoch_begin(soc_health_core_t *core)
{
    core->epoch++;
    (void)soc_health_report(core, SOC_IP_SYSTEM_SERVICE, SOC_STEP_PROGRESS,
                            core->epoch, 0u);
}

int soc_health_deadline_begin(soc_health_deadline_t *d,
                             uint32_t epoch, uint32_t budget, uint32_t token)
{
    d->armed = 0u;
    if (budget >= 0x80000000u) return 0;
    d->start_epoch = epoch;
    d->budget = budget;
    d->token = token;
    d->armed = 1u;
    return 1;
}

int soc_health_deadline_poll(soc_health_core_t *core, soc_ip_id_t id,
                            soc_health_deadline_t *d)
{
    if ((uint32_t)id >= SOC_IP_COUNT || id == SOC_IP_AES_GCM) return 0;
    if (!d->armed || core->epoch - d->start_epoch < d->budget) return 0;
    d->armed = 0u;
    return soc_health_report(core, id, SOC_STEP_DEADLINE_MISS, d->token, d->budget);
}

/* FNV-1a over explicit little-endian words; shift/add prime avoids RV32I mul. */
static uint32_t signature_word(uint32_t hash, uint32_t word)
{
    uint32_t i;
    for (i = 0u; i < 4u; i++) {
        hash ^= word & 0xffu;
        hash = hash + (hash << 1) + (hash << 4) + (hash << 7) +
               (hash << 8) + (hash << 24);
        word >>= 8;
    }
    return hash;
}

uint32_t soc_health_signature(const soc_health_snapshot_t *s)
{
    uint32_t hash = 2166136261u, i;
#define FIELD(value) hash = signature_word(hash, (uint32_t)(value))
    FIELD(0x53483201u);
    FIELD(s->epoch); FIELD(s->publication_id);
    FIELD(s->pass_mask); FIELD(s->warn_mask); FIELD(s->fail_mask);
    FIELD(s->excluded_mask); FIELD(s->sticky_fail_mask);
    FIELD(s->publication_backlog);
    for (i = 0u; i < 2u; i++) FIELD(s->observer_miss_count[i]);
    for (i = 0u; i < 2u; i++) FIELD(s->observer_last_epoch[i]);
    for (i = 0u; i < SOC_IP_COUNT; i++) {
        FIELD(i); FIELD(s->ip[i].state); FIELD(s->ip[i].evidence);
        FIELD(s->ip[i].heartbeat_count); FIELD(s->ip[i].last_progress_epoch);
        FIELD(s->ip[i].miss_count); FIELD(s->ip[i].detail);
    }
#undef FIELD
    return hash;
}

const soc_health_snapshot_t *soc_health_publish_snapshot(soc_health_core_t *core)
{
    uint32_t n, i;
    soc_health_slot_t *slot = 0;
    soc_health_snapshot_t *s;
    for (n = 0u; n < 2u; n++) {
        uint32_t index = (core->next_slot + n) & 1u;
        if (core->slot[index].readers == 0u) {
            slot = &core->slot[index];
            core->next_slot = index ^ 1u;
            break;
        }
    }
    if (slot == 0) { core->publication_backlog++; return 0; }
    s = &slot->snapshot;
    s->epoch = core->epoch;
    s->publication_id = ++core->publication_id;
    s->pass_mask = s->warn_mask = s->fail_mask = s->excluded_mask = 0u;
    s->sticky_fail_mask = core->sticky_fail_mask;
    s->publication_backlog = core->publication_backlog;
    for (i = 0u; i < 2u; i++) {
        s->observer_miss_count[i] = core->observer_miss_count[i];
        s->observer_last_epoch[i] = core->observer_last_epoch[i];
    }
    for (i = 0u; i < SOC_IP_COUNT; i++) {
        const soc_ip_health_t *in = &core->ip[i];
        soc_ip_health_t *out = &s->ip[i];
        out->state = in->state; out->evidence = in->evidence;
        out->heartbeat_count = in->heartbeat_count;
        out->last_progress_epoch = in->last_progress_epoch;
        out->miss_count = in->miss_count; out->detail = in->detail;
        switch (out->state) {
        case SOC_HB_PASS: s->pass_mask |= 1u << i; break;
        case SOC_HB_WARN: s->warn_mask |= 1u << i; break;
        case SOC_HB_FAIL: s->fail_mask |= 1u << i; break;
        case SOC_HB_EXCLUDED: s->excluded_mask |= 1u << i; break;
        default: break;
        }
    }
    s->signature = soc_health_signature(s);
    slot->readers = SOC_OBSERVER_BOTH;
    return s;
}

int soc_health_snapshot_release(soc_health_core_t *core,
                                const soc_health_snapshot_t *s,
                                uint32_t observer, int completed)
{
    uint32_t i, index;
    if (observer != SOC_OBSERVER_VGA && observer != SOC_OBSERVER_UART) return 0;
    index = observer == SOC_OBSERVER_VGA ? 0u : 1u;
    for (i = 0u; i < 2u; i++) {
        soc_health_slot_t *slot = &core->slot[i];
        if (&slot->snapshot == s && (slot->readers & observer) != 0u) {
            slot->readers &= ~observer;
            if (completed) core->observer_last_epoch[index] = s->epoch;
            else core->observer_miss_count[index]++;
            return 1;
        }
    }
    return 0;
}
