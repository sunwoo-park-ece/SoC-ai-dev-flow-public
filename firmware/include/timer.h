#ifndef TIMER_H
#define TIMER_H

#include <stdint.h>

#define TIMER_CTRL_START   (1u << 0)
#define TIMER_CTRL_RELOAD  (1u << 1)
#define TIMER_STATUS_READY (1u << 0)

void timer_start(uint32_t compare);
void timer_stop(void);
void timer_reload(void);
uint32_t timer_count(void);
uint32_t timer_status(void);
void timer_clear_ready(void);
void timer_wait_ready(void);
void timer_delay_cycles(uint32_t cycles);

#endif
