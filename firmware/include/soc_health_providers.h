#ifndef SOC_HEALTH_PROVIDERS_H
#define SOC_HEALTH_PROVIDERS_H
#include "soc_health.h"
#include "adc.h"

#define SOC_HEALTH_PROVIDER_BUDGET 262144u
#define SOC_HEALTH_TIMER_COMPARE 50000u
#define SOC_HEALTH_UART_RX_QUOTA 4u

typedef struct {
    soc_health_deadline_t deadline;
    uint32_t phase, attempt, generation, baseline;
} soc_health_transaction_t;
typedef struct {
    uint32_t next_provider, init_index, budget, timer_compare;
    uint32_t visits[SOC_IP_COUNT];
    soc_health_transaction_t timer, uart, gsensor, adc, vga;
    uint32_t uart_seq, uart_tx, uart_rx;
    uint8_t uart_frame[12];
    uint32_t adc_count, adc_error;
    uint16_t adc_center_x, adc_center_y, adc_deadzone;
    adc_frame_t frame;
    uint8_t frame_eligible;
    void *vga_context;
    int (*vga_prepare)(soc_health_core_t *, void *);
    void (*vga_release)(soc_health_core_t *, void *, int);
    void *board_context;
    void (*board_service)(soc_health_core_t *, void *, soc_ip_id_t);
} soc_health_providers_t;

void soc_health_providers_init(soc_health_providers_t *providers);
soc_ip_id_t soc_health_providers_service(soc_health_core_t *core,
                                         soc_health_providers_t *providers);
/* One bounded step each; public for transaction-level verification. */
void soc_health_timer_service(soc_health_core_t *, soc_health_providers_t *);
void soc_health_uart_service(soc_health_core_t *, soc_health_providers_t *);
void soc_health_gsensor_service(soc_health_core_t *, soc_health_providers_t *);
void soc_health_adc_service(soc_health_core_t *, soc_health_providers_t *);
void soc_health_joy_service(soc_health_core_t *, soc_health_providers_t *);
void soc_health_vga_service(soc_health_core_t *, soc_health_providers_t *);
#endif
