#include "soc_health.h"

void soc_health_render_init(soc_health_render_t *render)
{
    uint32_t i;
    render->snapshot = 0;
    render->start_epoch = render->pending = 0u;
    for (i = 0u; i < 2u; i++) {
        render->observer[i].source = 0;
        render->observer[i].position = 0u;
        render->observer[i].epoch = render->observer[i].signature = 0u;
        render->observer[i].last_char = '\0';
        render->observer[i].done = 0u;
    }
}

int soc_health_render_begin(soc_health_render_t *render,
                            const soc_health_snapshot_t *s, uint32_t epoch)
{
    uint32_t i;
    if (s == 0 || render->pending != 0u) return 0;
    render->snapshot = s;
    render->start_epoch = epoch;
    render->pending = SOC_OBSERVER_BOTH;
    for (i = 0u; i < 2u; i++) {
        render->observer[i].source = s;
        render->observer[i].position = 0u;
        render->observer[i].epoch = s->epoch;
        render->observer[i].signature = s->signature;
        render->observer[i].last_char = '\0';
        render->observer[i].done = 0u;
    }
    return 1;
}

static void render_step(const soc_health_snapshot_t *s, soc_health_observer_t *o)
{
    static const char hex[] = "0123456789ABCDEF";
    uint32_t p = o->position;
    if (o->done || o->source != s) return;
    /* Bounded placeholder text only: EPOCH=xxxxxxxx SIG=xxxxxxxx. No output MMIO. */
    if (p < 6u) o->last_char = "EPOCH="[p];
    else if (p < 14u) o->last_char = hex[(s->epoch >> ((13u - p) << 2)) & 15u];
    else if (p < 19u) o->last_char = " SIG="[p - 14u];
    else o->last_char = hex[(s->signature >> ((26u - p) << 2)) & 15u];
    o->position++;
    if (o->position == 27u) o->done = 1u;
}

void soc_health_render_vga_step(const soc_health_snapshot_t *s,
                               soc_health_observer_t *observer)
{
    render_step(s, observer);
}

void soc_health_render_uart_step(const soc_health_snapshot_t *s,
                                soc_health_observer_t *observer)
{
    render_step(s, observer);
}

void soc_health_render_service(soc_health_core_t *core, soc_health_render_t *render,
                              uint32_t ready_mask)
{
    uint32_t i;
    for (i = 0u; i < 2u; i++) {
        uint32_t bit = 1u << i;
        if ((render->pending & bit) == 0u) continue;
        if (core->epoch - render->start_epoch >= SOC_HEALTH_RENDER_BUDGET) {
            (void)soc_health_snapshot_release(core, render->snapshot, bit, 0);
            render->pending &= ~bit;
            render->observer[i].source = 0;
            continue;
        }
        if ((ready_mask & bit) == 0u) continue;
        if (i == 0u) soc_health_render_vga_step(render->snapshot, &render->observer[i]);
        else soc_health_render_uart_step(render->snapshot, &render->observer[i]);
        if (render->observer[i].done) {
            (void)soc_health_snapshot_release(core, render->snapshot, bit, 1);
            render->pending &= ~bit;
            render->observer[i].source = 0;
        }
    }
    if (render->pending == 0u) render->snapshot = 0;
}
