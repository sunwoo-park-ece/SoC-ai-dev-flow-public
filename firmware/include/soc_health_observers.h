#ifndef SOC_HEALTH_OBSERVERS_H
#define SOC_HEALTH_OBSERVERS_H
#include "soc_health.h"
#define SOC_HEALTH_TEXT_LINES 19u
#define SOC_HEALTH_LINE_SIZE 48u
#define SOC_HEALTH_OBSERVER_BUDGET 262144u
#define SOC_HEALTH_VGA_X 32u /* existing renderer writes aligned 32-bit words */
#define SOC_HEALTH_VGA_Y 16u
#define SOC_HEALTH_VGA_PITCH 16u
#define SOC_HEALTH_CLEAR_QUOTA 8u
typedef struct {
    const soc_health_snapshot_t *vga_snapshot, *uart_snapshot;
    uint32_t pending, start_epoch, budget;
    uint32_t clear_word, vga_line, vga_column;
    uint32_t uart_stage, uart_line, uart_column, uart_length;
    char vga_buffer[SOC_HEALTH_LINE_SIZE], uart_buffer[SOC_HEALTH_LINE_SIZE];
} soc_health_observers_t;
/* Returns the untruncated logical length; size>0 always terminates the buffer.
 * Line 3/17 are blank; out-of-range lines are empty. No MMIO or live state. */
unsigned soc_health_format_line(const soc_health_snapshot_t *, unsigned,
                                char *, unsigned);
void soc_health_observers_init(soc_health_observers_t *);
int soc_health_observers_begin(soc_health_observers_t *,
                              const soc_health_snapshot_t *, uint32_t);
void soc_health_observers_uart_service(soc_health_core_t *,soc_health_observers_t *);
/* Hooks called exclusively by the existing S3 VGA transaction owner. */
int soc_health_observers_vga_prepare(soc_health_core_t *,void *);
void soc_health_observers_vga_release(soc_health_core_t *,void *,int);
#endif
