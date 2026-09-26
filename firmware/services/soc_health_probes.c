#include "soc_health.h"

/* S2 placeholders: NOT QUALIFYING HARDWARE EVIDENCE. No MMIO or AES callback. */
static const soc_ip_id_t providers[] = {
    SOC_IP_TIMER, SOC_IP_UART_LOOP, SOC_IP_GPIO, SOC_IP_GSENSOR, SOC_IP_ADC,
    SOC_IP_JOY_POLICY, SOC_IP_VGA, SOC_IP_SW, SOC_IP_LED, SOC_IP_HEX
};

void soc_health_probes_init(soc_health_probes_t *probes)
{
    probes->next_provider = probes->service_count = 0u;
}

soc_ip_id_t soc_health_probe_service(soc_health_core_t *core, soc_health_probes_t *probes)
{
    soc_ip_id_t id = providers[probes->next_provider];
    (void)soc_health_report(core, id, SOC_STEP_PENDING, 0u,
                            SOC_HEALTH_NOT_IMPLEMENTED);
    probes->service_count++;
    probes->next_provider++;
    if (probes->next_provider == sizeof(providers) / sizeof(providers[0]))
        probes->next_provider = 0u;
    return id;
}
