#include "soc_health.h"
#include "soc_health_providers.h"
#include "soc_health_board_io.h"
#include "soc_health_observers.h"

static soc_health_core_t health;
static soc_health_providers_t probes;
static soc_health_observers_t render;
static soc_health_board_io_t board;

int main(void)
{
    uint32_t last_publication = 0u;
    soc_health_init(&health);
    soc_health_providers_init(&probes);
    soc_health_board_io_init(&board);
    probes.board_context = &board;
    probes.board_service = soc_health_board_io_service;
    soc_health_observers_init(&render);
    probes.vga_context = &render;
    probes.vga_prepare = soc_health_observers_vga_prepare;
    probes.vga_release = soc_health_observers_vga_release;
    for (;;) {
        soc_health_epoch_begin(&health);
        soc_health_providers_service(&health, &probes);
        soc_health_observers_uart_service(&health, &render);
        if (health.epoch - last_publication >= SOC_HEALTH_REPORT_PERIOD) {
            if (render.pending == 0u) {
                const soc_health_snapshot_t *snapshot = soc_health_publish_snapshot(&health);
                if (snapshot != 0) {
                    (void)soc_health_observers_begin(&render, snapshot, health.epoch);
                    last_publication = health.epoch;
                }
            } else health.publication_backlog++;
        }
    }
}
