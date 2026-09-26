#ifndef SOC_HEALTH_H
#define SOC_HEALTH_H

#include <stdint.h>

/* Stable mask/signature ABI. Append future IDs only through contract review. */
typedef enum {
    SOC_IP_SYSTEM_SERVICE = 0, SOC_IP_TIMER = 1, SOC_IP_UART_LOOP = 2,
    SOC_IP_GPIO = 3, SOC_IP_GSENSOR = 4, SOC_IP_ADC = 5,
    SOC_IP_JOY_POLICY = 6, SOC_IP_VGA = 7, SOC_IP_SW = 8,
    SOC_IP_LED = 9, SOC_IP_HEX = 10, SOC_IP_AES_GCM = 11,
    SOC_IP_COUNT = 12
} soc_ip_id_t;

typedef enum {
    SOC_HB_UNKNOWN = 0, SOC_HB_PASS, SOC_HB_WARN, SOC_HB_FAIL, SOC_HB_EXCLUDED
} soc_hb_state_t;
typedef enum {
    SOC_EV_STRONG_PROGRESS = 0, SOC_EV_PHYSICAL_LOOPBACK,
    SOC_EV_FUNCTIONAL_CONSISTENCY, SOC_EV_REGISTER_READBACK,
    SOC_EV_INPUT_OBSERVATION, SOC_EV_VISIBLE_OUTPUT,
    SOC_EV_OBSERVER_ONLY, SOC_EV_EXCLUDED
} soc_evidence_t;
typedef enum {
    SOC_STEP_PENDING = 0, SOC_STEP_PROGRESS, SOC_STEP_WARN,
    SOC_STEP_FAIL, SOC_STEP_DEADLINE_MISS
} soc_health_step_t;

#define SOC_HEALTH_NOT_IMPLEMENTED 0x4e4f5451u /* NOT QUALIFYING HARDWARE EVIDENCE */
#define SOC_HEALTH_AES_PENDING    0x41455358u /* EXCLUDED_PENDING_CLEANUP */
#define SOC_OBSERVER_VGA          1u
#define SOC_OBSERVER_UART         2u
#define SOC_OBSERVER_BOTH         3u
#define SOC_HEALTH_RENDER_BUDGET  64u
#define SOC_HEALTH_REPORT_PERIOD  32u

typedef struct {
    uint8_t state;
    uint8_t evidence;
    uint32_t heartbeat_count;
    uint32_t last_progress_epoch;
    uint32_t miss_count;
    uint32_t detail;
} soc_ip_health_t;

typedef struct {
    uint32_t epoch, publication_id, signature;
    uint32_t pass_mask, warn_mask, fail_mask, excluded_mask, sticky_fail_mask;
    uint32_t publication_backlog;
    uint32_t observer_miss_count[2], observer_last_epoch[2];
    soc_ip_health_t ip[SOC_IP_COUNT];
} soc_health_snapshot_t;

typedef struct {
    soc_health_snapshot_t snapshot;
    uint32_t readers; /* Mutable storage ownership is outside signed content. */
} soc_health_slot_t;
typedef struct {
    soc_ip_health_t ip[SOC_IP_COUNT];
    uint32_t epoch, publication_id, sticky_fail_mask, next_slot;
    uint32_t publication_backlog;
    uint32_t observer_miss_count[2], observer_last_epoch[2];
    uint32_t progress_token[SOC_IP_COUNT], miss_token[SOC_IP_COUNT];
    uint8_t progress_seen[SOC_IP_COUNT], miss_seen[SOC_IP_COUNT];
    soc_health_slot_t slot[2];
} soc_health_core_t;
typedef struct {
    uint32_t start_epoch, budget, token;
    uint8_t armed;
} soc_health_deadline_t;
typedef struct { uint32_t next_provider, service_count; } soc_health_probes_t;
typedef struct {
    const soc_health_snapshot_t *source;
    uint32_t position, epoch, signature;
    char last_char;
    uint8_t done;
} soc_health_observer_t;
typedef struct {
    const soc_health_snapshot_t *snapshot;
    soc_health_observer_t observer[2];
    uint32_t start_epoch, pending;
} soc_health_render_t;

void soc_health_init(soc_health_core_t *core);
void soc_health_epoch_begin(soc_health_core_t *core);
/* Single owner. Tokens advance modulo 2^32 by <2^31 per IP/event stream.
 * Replayed/old completions do not qualify a new event or recover a failure. */
int soc_health_report(soc_health_core_t *core, soc_ip_id_t id,
                      soc_health_step_t step, uint32_t token, uint32_t detail);
int soc_health_deadline_begin(soc_health_deadline_t *deadline,
                             uint32_t epoch, uint32_t budget, uint32_t token);
int soc_health_deadline_poll(soc_health_core_t *core, soc_ip_id_t id,
                            soc_health_deadline_t *deadline);
const soc_health_snapshot_t *soc_health_publish_snapshot(soc_health_core_t *core);
int soc_health_snapshot_release(soc_health_core_t *core,
                                const soc_health_snapshot_t *snapshot,
                                uint32_t observer, int completed);
uint32_t soc_health_signature(const soc_health_snapshot_t *snapshot);
void soc_health_probes_init(soc_health_probes_t *probes);
soc_ip_id_t soc_health_probe_service(soc_health_core_t *core, soc_health_probes_t *probes);
void soc_health_render_init(soc_health_render_t *render);
int soc_health_render_begin(soc_health_render_t *render,
                            const soc_health_snapshot_t *snapshot, uint32_t epoch);
void soc_health_render_vga_step(const soc_health_snapshot_t *snapshot,
                               soc_health_observer_t *observer);
void soc_health_render_uart_step(const soc_health_snapshot_t *snapshot,
                                soc_health_observer_t *observer);
/* ready_mask controls placeholder sink readiness; there is no S2 MMIO. */
void soc_health_render_service(soc_health_core_t *core, soc_health_render_t *render,
                              uint32_t ready_mask);
#endif
