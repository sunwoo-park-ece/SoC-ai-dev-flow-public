#include "soc_health.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

#define CHECK(id, condition) do { if (!(condition)) { \
    fprintf(stderr, "ASSERT %s failed at line %d: %s\n", id, __LINE__, #condition); \
    exit(1); } } while (0)

uint32_t soc_health_forbidden_read(uint32_t address)
{
    (void)address; CHECK("NO_MMIO", 0); return 0u;
}
void soc_health_forbidden_write(uint32_t address, uint32_t value)
{
    (void)address; (void)value; CHECK("NO_MMIO", 0);
}

static void release_both(soc_health_core_t *c, const soc_health_snapshot_t *s)
{
    CHECK("LEASE_RELEASE", soc_health_snapshot_release(c, s, 1u, 1));
    CHECK("LEASE_RELEASE", soc_health_snapshot_release(c, s, 2u, 1));
}

static void state_tests(void)
{
    soc_health_core_t c;
    const soc_health_snapshot_t *s;
    uint32_t i;
    const soc_ip_id_t ids[12] = { SOC_IP_SYSTEM_SERVICE, SOC_IP_TIMER,
        SOC_IP_UART_LOOP, SOC_IP_GPIO, SOC_IP_GSENSOR, SOC_IP_ADC,
        SOC_IP_JOY_POLICY, SOC_IP_VGA, SOC_IP_SW, SOC_IP_LED, SOC_IP_HEX,
        SOC_IP_AES_GCM };
    soc_health_init(&c);
    for (i = 0u; i < 12u; i++) {
        CHECK("STABLE_IDS", (uint32_t)ids[i] == i);
        CHECK("DEFAULT_STATE", c.ip[i].state == (i == 11u ? SOC_HB_EXCLUDED : SOC_HB_UNKNOWN));
        CHECK("DEFAULT_COUNTERS", c.ip[i].heartbeat_count == 0u && c.ip[i].miss_count == 0u);
    }
    s = soc_health_publish_snapshot(&c);
    CHECK("DEFAULT_MASKS", s && s->pass_mask == 0u && s->warn_mask == 0u &&
          s->fail_mask == 0u && s->sticky_fail_mask == 0u && s->excluded_mask == 0x800u);
    release_both(&c, s);
    CHECK("STATE_REPORT", soc_health_report(&c, SOC_IP_TIMER, SOC_STEP_PROGRESS, 7u, 42u));
    CHECK("STATE_REPORT", soc_health_report(&c, SOC_IP_UART_LOOP, SOC_STEP_WARN, 0u, 13u));
    CHECK("STATE_REPORT", soc_health_report(&c, SOC_IP_GPIO, SOC_STEP_FAIL, 0u, 99u));
    s = soc_health_publish_snapshot(&c);
    CHECK("STATE_MASKS", s->pass_mask == 2u && s->warn_mask == 4u &&
          s->fail_mask == 8u && s->sticky_fail_mask == 8u && s->excluded_mask == 0x800u);
    CHECK("DETAIL_COPY", s->ip[1].detail == 42u && s->ip[3].detail == 99u);
    release_both(&c, s);
    CHECK("RECOVERY", soc_health_report(&c, SOC_IP_GPIO, SOC_STEP_PROGRESS, 1u, 1u));
    s = soc_health_publish_snapshot(&c);
    CHECK("STICKY_RECOVERY", s->fail_mask == 0u && s->pass_mask == 10u && s->sticky_fail_mask == 8u);
    release_both(&c, s);
    for (i = 0u; i <= SOC_STEP_DEADLINE_MISS; i++)
        CHECK("AES_REJECT", !soc_health_report(&c, SOC_IP_AES_GCM, (soc_health_step_t)i, i, i));
    s = soc_health_publish_snapshot(&c);
    CHECK("AES_EXCLUDED", s->ip[11].state == SOC_HB_EXCLUDED && s->excluded_mask == 0x800u &&
          (s->pass_mask & 0x800u) == 0u && (s->fail_mask & 0x800u) == 0u &&
          (s->sticky_fail_mask & 0x800u) == 0u && s->ip[11].heartbeat_count == 0u);
    release_both(&c, s);
    CHECK("INVALID_ID", !soc_health_report(&c, (soc_ip_id_t)-1, SOC_STEP_FAIL, 0, 0));
    soc_health_init(&c);
    CHECK("REBOOT_CLEAR", c.sticky_fail_mask == 0u);
    for (i = 0u; i < 11u; i++) {
        uint32_t bit = 1u << i;
        soc_health_init(&c);
        (void)soc_health_report(&c, ids[i], SOC_STEP_PROGRESS, 0u, 1u);
        s = soc_health_publish_snapshot(&c);
        CHECK("MASK_PER_ID", s->pass_mask == bit && s->warn_mask == 0u && s->fail_mask == 0u);
        release_both(&c, s);
        (void)soc_health_report(&c, ids[i], SOC_STEP_WARN, 0u, 2u);
        s = soc_health_publish_snapshot(&c);
        CHECK("MASK_PER_ID", s->warn_mask == bit && s->pass_mask == 0u && s->fail_mask == 0u);
        release_both(&c, s);
        (void)soc_health_report(&c, ids[i], SOC_STEP_FAIL, 0u, 3u);
        s = soc_health_publish_snapshot(&c);
        CHECK("MASK_PER_ID", s->fail_mask == bit && s->sticky_fail_mask == bit && s->excluded_mask == 0x800u);
        release_both(&c, s);
    }
    puts("CASE state_masks_sticky_aes PASS");
}

static void counter_tests(void)
{
    soc_health_core_t c;
    soc_health_deadline_t d;
    uint32_t i;
    soc_health_init(&c); c.epoch = 100u;
    for (i = 0u; i < 50u; i++)
        (void)soc_health_report(&c, SOC_IP_TIMER, SOC_STEP_PENDING, 7u, i);
    CHECK("PENDING_NO_PROGRESS", c.ip[1].heartbeat_count == 0u && c.ip[1].miss_count == 0u && c.ip[1].state == SOC_HB_UNKNOWN);
    CHECK("PROGRESS_ONCE", soc_health_report(&c, SOC_IP_TIMER, SOC_STEP_PROGRESS, 7u, 0u));
    for (i = 0u; i < 50u; i++)
        CHECK("DUPLICATE_REJECT", !soc_health_report(&c, SOC_IP_TIMER, SOC_STEP_PROGRESS, 7u, 0u));
    CHECK("PROGRESS_ONCE", c.ip[1].heartbeat_count == 1u && c.ip[1].last_progress_epoch == 100u);
    CHECK("DEADLINE_START", soc_health_deadline_begin(&d, 100u, 3u, 9u));
    c.epoch = 102u; CHECK("DEADLINE_PENDING", !soc_health_deadline_poll(&c, SOC_IP_TIMER, &d));
    c.epoch = 103u; CHECK("DEADLINE_ONCE", soc_health_deadline_poll(&c, SOC_IP_TIMER, &d));
    CHECK("DEADLINE_ONCE", !soc_health_deadline_poll(&c, SOC_IP_TIMER, &d) && c.ip[1].miss_count == 1u);
    CHECK("DEADLINE_FAIL", c.ip[1].state == SOC_HB_FAIL && c.sticky_fail_mask == 2u);
    CHECK("STALE_NO_RECOVERY", !soc_health_report(&c, SOC_IP_TIMER, SOC_STEP_PROGRESS, 7u, 0u));
    CHECK("STALE_NO_RECOVERY", c.ip[1].state == SOC_HB_FAIL);
    CHECK("FRESH_RECOVERY", soc_health_report(&c, SOC_IP_TIMER, SOC_STEP_PROGRESS, 8u, 0u));
    CHECK("COUNTER_RECOVERY", c.ip[1].heartbeat_count == 2u && c.ip[1].miss_count == 1u && c.sticky_fail_mask == 2u);
    CHECK("DUPLICATE_MISS", !soc_health_report(&c, SOC_IP_TIMER, SOC_STEP_DEADLINE_MISS, 9u, 0u));
    soc_health_init(&c);
    CHECK("TOKEN_WRAP", soc_health_report(&c, SOC_IP_ADC, SOC_STEP_PROGRESS, 0xfffffffeu, 0u));
    CHECK("TOKEN_WRAP", soc_health_report(&c, SOC_IP_ADC, SOC_STEP_PROGRESS, 1u, 0u));
    CHECK("TOKEN_OLD", !soc_health_report(&c, SOC_IP_ADC, SOC_STEP_PROGRESS, 0u, 0u));
    CHECK("DEADLINE_WRAP", soc_health_deadline_begin(&d, 0xfffffffeu, 3u, 1u));
    c.epoch = 0u; CHECK("DEADLINE_WRAP", !soc_health_deadline_poll(&c, SOC_IP_ADC, &d));
    c.epoch = 1u; CHECK("DEADLINE_WRAP", soc_health_deadline_poll(&c, SOC_IP_ADC, &d));
    CHECK("DEADLINE_INVALID", !soc_health_deadline_begin(&d, 0u, 0x80000000u, 1u) && !d.armed);
    CHECK("ZERO_DEADLINE", soc_health_deadline_begin(&d, 1u, 0u, 2u));
    CHECK("ZERO_DEADLINE", soc_health_deadline_poll(&c, SOC_IP_ADC, &d));
    puts("CASE counters_deadlines_tokens PASS");
}

static void snapshot_tests(void)
{
    soc_health_core_t c;
    const soc_health_snapshot_t *n, *m, *next;
    unsigned char saved[sizeof(soc_health_snapshot_t)];
    soc_health_init(&c); soc_health_epoch_begin(&c);
    n = soc_health_publish_snapshot(&c); CHECK("SNAPSHOT_EXISTS", n != 0);
    memcpy(saved, n, sizeof(saved));
    (void)soc_health_report(&c, SOC_IP_TIMER, SOC_STEP_FAIL, 0u, 123u);
    soc_health_epoch_begin(&c);
    CHECK("SNAPSHOT_COPY", memcmp(saved, n, sizeof(saved)) == 0);
    m = soc_health_publish_snapshot(&c);
    CHECK("SNAPSHOT_DELTA", m && m != n && m->epoch == 2u && n->epoch == 1u &&
          n->fail_mask == 0u && m->fail_mask == 2u && m->publication_id == n->publication_id + 1u);
    CHECK("LEASE_FULL", soc_health_publish_snapshot(&c) == 0 && c.publication_backlog == 1u);
    CHECK("LEASE_PARTIAL", soc_health_snapshot_release(&c, n, 1u, 1));
    CHECK("LEASE_FULL", soc_health_publish_snapshot(&c) == 0);
    CHECK("LEASE_IMMUTABLE", memcmp(saved, n, sizeof(saved)) == 0);
    CHECK("LEASE_DUPLICATE", !soc_health_snapshot_release(&c, n, 1u, 1));
    CHECK("LEASE_INVALID", !soc_health_snapshot_release(&c, n, 3u, 1));
    CHECK("LEASE_LAST", soc_health_snapshot_release(&c, n, 2u, 1));
    next = soc_health_publish_snapshot(&c);
    CHECK("LEASE_REUSE", next == n && next->publication_backlog == 2u);
    release_both(&c, next); release_both(&c, m);
    puts("CASE snapshot_copy_leases PASS");
}

static void signature_fixture(soc_health_snapshot_t *s, int poison)
{
    uint32_t i;
    memset(s, poison, sizeof(*s));
    s->signature = 0u; s->epoch = 3u; s->publication_id = 4u;
    s->pass_mask = 1u; s->warn_mask = 2u; s->fail_mask = 4u;
    s->excluded_mask = 0x800u; s->sticky_fail_mask = 4u;
    s->publication_backlog = 9u;
    for (i = 0u; i < 2u; i++) { s->observer_miss_count[i] = i; s->observer_last_epoch[i] = i + 1u; }
    for (i = 0u; i < 12u; i++) {
        s->ip[i].state = (uint8_t)(i % 5u); s->ip[i].evidence = (uint8_t)(i % 8u);
        s->ip[i].heartbeat_count = i + 11u; s->ip[i].last_progress_epoch = i + 12u;
        s->ip[i].miss_count = i + 13u; s->ip[i].detail = i + 14u;
    }
}

/* Spec-derived serialization and 64-bit host multiply differ from DUT shift/add. */
static uint32_t reference_signature(const soc_health_snapshot_t *s)
{
    uint32_t words[97], count = 0u, i, byte;
    uint32_t hash = 2166136261u;
#define ADD(v) words[count++] = (uint32_t)(v)
    ADD(0x53483201u); ADD(s->epoch); ADD(s->publication_id);
    ADD(s->pass_mask); ADD(s->warn_mask); ADD(s->fail_mask); ADD(s->excluded_mask);
    ADD(s->sticky_fail_mask); ADD(s->publication_backlog);
    ADD(s->observer_miss_count[0]); ADD(s->observer_miss_count[1]);
    ADD(s->observer_last_epoch[0]); ADD(s->observer_last_epoch[1]);
    for (i = 0u; i < 12u; i++) {
        ADD(i); ADD(s->ip[i].state); ADD(s->ip[i].evidence); ADD(s->ip[i].heartbeat_count);
        ADD(s->ip[i].last_progress_epoch); ADD(s->ip[i].miss_count); ADD(s->ip[i].detail);
    }
#undef ADD
    CHECK("SIGNATURE_SCHEMA", count == 97u);
    for (i = 0u; i < count; i++)
        for (byte = 0u; byte < 4u; byte++)
            hash = (uint32_t)((uint64_t)(hash ^ ((words[i] >> (byte * 8u)) & 255u)) * 16777619u);
    return hash;
}

static void signature_tests(void)
{
    soc_health_snapshot_t a, b;
    uint32_t base, i, j;
    signature_fixture(&a, 0x55); signature_fixture(&b, 0xaa);
    base = soc_health_signature(&a);
    CHECK("SIGNATURE_PADDING", base == soc_health_signature(&b));
    CHECK("SIGNATURE_ORACLE", base == reference_signature(&a));
    CHECK("SIGNATURE_REPEAT", base == soc_health_signature(&a));
    b.signature = 0xffffffffu;
    CHECK("SIGNATURE_EXCLUDED_SELF", base == soc_health_signature(&b));
    /* Exhaust every included mutable logical field, never opaque memory/padding. */
    for (i = 0u; i < 12u; i++) {
        uint32_t *fields[12];
        signature_fixture(&b, 0xaa);
        fields[0]=&b.epoch; fields[1]=&b.publication_id; fields[2]=&b.pass_mask;
        fields[3]=&b.warn_mask; fields[4]=&b.fail_mask; fields[5]=&b.excluded_mask;
        fields[6]=&b.sticky_fail_mask; fields[7]=&b.publication_backlog;
        fields[8]=&b.observer_miss_count[0]; fields[9]=&b.observer_miss_count[1];
        fields[10]=&b.observer_last_epoch[0]; fields[11]=&b.observer_last_epoch[1];
        (*fields[i])++;
        CHECK("SIGNATURE_HEADER_FIELD", soc_health_signature(&b) != base);
        for (j = 0u; j < 6u; j++) {
            signature_fixture(&b, 0xaa);
            switch (j) {
            case 0: b.ip[i].state++; break; case 1: b.ip[i].evidence++; break;
            case 2: b.ip[i].heartbeat_count++; break; case 3: b.ip[i].last_progress_epoch++; break;
            case 4: b.ip[i].miss_count++; break; default: b.ip[i].detail++; break;
            }
            CHECK("SIGNATURE_RECORD_FIELD", soc_health_signature(&b) != base);
        }
    }
    puts("CASE signature_oracle_padding_fields PASS");
}

static void observer_tests(void)
{
    soc_health_core_t c;
    soc_health_render_t render;
    const soc_health_snapshot_t *s, *next;
    unsigned char saved[sizeof(soc_health_snapshot_t)];
    char expected[28]; uint32_t i;
    soc_health_init(&c); soc_health_epoch_begin(&c);
    s = soc_health_publish_snapshot(&c); memcpy(saved, s, sizeof(saved));
    soc_health_render_init(&render);
    CHECK("OBSERVER_BEGIN", soc_health_render_begin(&render, s, c.epoch));
    CHECK("OBSERVER_SAME_OBJECT", render.observer[0].source == s && render.observer[1].source == s);
    CHECK("OBSERVER_BUSY", !soc_health_render_begin(&render, s, c.epoch));
    (void)snprintf(expected, sizeof(expected), "EPOCH=%08X SIG=%08X", s->epoch, s->signature);
    for (i = 0u; i < 27u; i++) {
        soc_health_render_vga_step(s, &render.observer[0]);
        soc_health_render_uart_step(s, &render.observer[1]);
        CHECK("OBSERVER_TEXT", render.observer[0].last_char == expected[i] && render.observer[1].last_char == expected[i]);
        CHECK("OBSERVER_BOUND", render.observer[0].position == i + 1u && render.observer[1].position == i + 1u);
    }
    CHECK("OBSERVER_IMMUTABLE", memcmp(saved, s, sizeof(saved)) == 0);
    CHECK("OBSERVER_IDENTITY", render.observer[0].epoch == s->epoch && render.observer[1].signature == s->signature);
    soc_health_render_service(&c, &render, 3u); /* Release completed cursors. */
    CHECK("OBSERVER_COMPLETE", render.pending == 0u && c.observer_last_epoch[0] == 1u && c.observer_last_epoch[1] == 1u);
    s = soc_health_publish_snapshot(&c); memcpy(saved, s, sizeof(saved));
    CHECK("OBSERVER_BEGIN", soc_health_render_begin(&render, s, c.epoch));
    for (i = 0u; i < 27u; i++) { soc_health_epoch_begin(&c); soc_health_render_service(&c, &render, 1u); }
    CHECK("OBSERVER_SLOW", render.pending == 2u && render.observer[1].position == 0u);
    next = soc_health_publish_snapshot(&c);
    CHECK("OBSERVER_NO_OVERWRITE", next && next != s && soc_health_publish_snapshot(&c) == 0);
    CHECK("OBSERVER_IMMUTABLE", memcmp(saved, s, sizeof(saved)) == 0);
    c.epoch = render.start_epoch + 64u;
    soc_health_render_service(&c, &render, 0u);
    CHECK("OBSERVER_TIMEOUT", render.pending == 0u && c.observer_miss_count[1] == 1u && c.observer_miss_count[0] == 0u);
    CHECK("OBSERVER_IMMUTABLE", memcmp(saved, s, sizeof(saved)) == 0);
    release_both(&c, next);
    next = soc_health_publish_snapshot(&c);
    CHECK("OBSERVER_FUTURE_METADATA", next->observer_miss_count[1] == 1u && next->publication_backlog == 1u);
    release_both(&c, next);
    puts("CASE observer_identity_text_slow_timeout PASS");
}

static void scheduler_tests(void)
{
    soc_health_core_t c;
    soc_health_probes_t probes;
    uint32_t i, j;
    soc_health_init(&c); soc_health_probes_init(&probes);
    for (i = 0u; i < 100u; i++) {
        soc_health_epoch_begin(&c);
        CHECK("PROBE_FAIRNESS", (uint32_t)soc_health_probe_service(&c, &probes) == (i % 10u) + 1u);
        CHECK("EPOCH_NO_TIMER", c.epoch == i + 1u && c.ip[0].heartbeat_count == i + 1u);
        for (j = 1u; j < 11u; j++)
            CHECK("PLACEHOLDER_UNKNOWN", c.ip[j].state == SOC_HB_UNKNOWN && c.ip[j].heartbeat_count == 0u);
        CHECK("AES_NEVER_PROBED", c.ip[11].state == SOC_HB_EXCLUDED && c.ip[11].detail == SOC_HEALTH_AES_PENDING);
    }
    puts("CASE scheduler_placeholders_no_mmio PASS");
}

int main(void)
{
    state_tests(); counter_tests(); snapshot_tests(); signature_tests(); observer_tests(); scheduler_tests();
    puts("SUMMARY: PASS SOC_HEALTH_S2");
    return 0;
}
