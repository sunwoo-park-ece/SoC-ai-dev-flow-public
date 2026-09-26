#include "soc_health.h"

static soc_health_core_t health;
static soc_health_probes_t probes;
static soc_health_render_t render;

int main(void)
{
    uint32_t last_publication = 0u;
    soc_health_init(&health);
    soc_health_probes_init(&probes);
    soc_health_render_init(&render);
    for (;;) {
        soc_health_epoch_begin(&health);
        soc_health_probe_service(&health, &probes);
        soc_health_render_service(&health, &render, SOC_OBSERVER_BOTH);
        if (health.epoch - last_publication >= SOC_HEALTH_REPORT_PERIOD) {
            if (render.pending == 0u) {
                const soc_health_snapshot_t *snapshot = soc_health_publish_snapshot(&health);
                if (snapshot != 0) {
                    (void)soc_health_render_begin(&render, snapshot, health.epoch);
                    last_publication = health.epoch;
                }
            } else health.publication_backlog++;
        }
    }
}
