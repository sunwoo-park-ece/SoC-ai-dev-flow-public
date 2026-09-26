#include "soc_health_providers.h"
#include "timer.h"
#include "uart.h"
#include "gsensor.h"
#include "joystick_policy.h"
#include "vram.h"

/* Provider-local transaction phases, never health progress tokens. */
enum { START, WAIT_COUNT, WAIT_READY, ACK, RESTART, WAIT_RESTART };
enum { UART_INIT, UART_DRAIN, UART_TRANSFER };
enum { ADC_INIT, ADC_ENABLE, ADC_WAIT_ENABLE, ADC_CAPTURE };
enum { VGA_READY, VGA_PREPARE, VGA_ARM, VGA_FRESH, VGA_DONE };

static void arm(soc_health_core_t *c, soc_health_providers_t *p,
                soc_health_transaction_t *t)
{
    (void)soc_health_deadline_begin(&t->deadline, c->epoch, p->budget, ++t->attempt);
}
static int expired(soc_health_core_t *c, soc_ip_id_t id, soc_health_transaction_t *t)
{
    return soc_health_deadline_poll(c, id, &t->deadline);
}
static void fail(soc_health_core_t *c, soc_ip_id_t id, uint32_t detail)
{
    (void)soc_health_report(c, id, SOC_STEP_FAIL, 0u, detail);
}
static void init_transaction(soc_health_transaction_t *t)
{
    t->phase = t->attempt = t->generation = t->baseline = 0u;
    t->deadline.armed = 0u;
    t->deadline.start_epoch = t->deadline.budget = t->deadline.token = 0u;
}
void soc_health_providers_init(soc_health_providers_t *p)
{
    uint32_t i;
    p->next_provider = p->init_index = 0u;
    p->budget = SOC_HEALTH_PROVIDER_BUDGET;
    p->timer_compare = SOC_HEALTH_TIMER_COMPARE;
    for (i = 0; i < SOC_IP_COUNT; i++) p->visits[i] = 0u;
    init_transaction(&p->timer); init_transaction(&p->uart);
    init_transaction(&p->gsensor); init_transaction(&p->adc); init_transaction(&p->vga);
    p->uart_seq = p->uart_tx = p->uart_rx = 0u;
    for (i = 0; i < 12u; i++) p->uart_frame[i] = 0u;
    p->adc_count = p->adc_error = 0u;
    p->adc_center_x = p->adc_center_y = p->adc_deadzone = 0u;
    p->frame_eligible = 0u;
    p->frame.seq = 0u; p->frame.valid_mask = 0u;
    for (i = 0; i < 6u; i++) p->frame.ch[i] = 0u;
}

void soc_health_timer_service(soc_health_core_t *c, soc_health_providers_t *p)
{
    soc_health_transaction_t *t = &p->timer;
    uint32_t count, status;
    if (t->phase != START && expired(c, SOC_IP_TIMER, t)) {
        timer_stop(); t->phase = START; return;
    }
    switch (t->phase) {
    case START:
        arm(c, p, t);
        timer_stop(); timer_clear_ready(); timer_reload();
        timer_start(p->timer_compare);
        t->baseline = timer_count();
        if ((timer_status() & TIMER_STATUS_READY) != 0u) {
            fail(c, SOC_IP_TIMER, 0x1001u); timer_stop(); return;
        }
        t->phase = WAIT_COUNT; break;
    case WAIT_COUNT:
    case WAIT_RESTART:
        count = timer_count(); status = timer_status();
        if (count <= t->baseline) break;
        if (t->phase == WAIT_RESTART) {
            (void)soc_health_report(c, SOC_IP_TIMER, SOC_STEP_PROGRESS,
                                    ++t->generation, count);
            arm(c, p, t); /* new interval is already running */
        }
        t->phase = (status & TIMER_STATUS_READY) ? ACK : WAIT_READY; break;
    case WAIT_READY:
        if ((timer_status() & TIMER_STATUS_READY) != 0u) t->phase = ACK;
        break;
    case ACK:
        timer_clear_ready(); t->phase = RESTART; break;
    case RESTART:
        if ((timer_status() & TIMER_STATUS_READY) != 0u) {
            fail(c, SOC_IP_TIMER, 0x1002u); timer_stop(); t->phase = START; break;
        }
        timer_start(p->timer_compare); t->baseline = timer_count();
        if ((timer_status() & TIMER_STATUS_READY) != 0u) {
            fail(c, SOC_IP_TIMER, 0x1003u); timer_stop(); t->phase = START; break;
        }
        t->phase = WAIT_RESTART; break;
    default: fail(c, SOC_IP_TIMER, 0x1004u); t->phase = START; break;
    }
}

static uint8_t token_byte(uint32_t seq, uint32_t index)
{
    if (index == 0u) return 0xa5u;
    if (index == 1u) return 0x5au;
    if (index < 6u) return (uint8_t)(seq >> ((index - 2u) << 3));
    if (index < 10u) return (uint8_t)(~seq >> ((index - 6u) << 3));
    return index == 10u ? 0xc3u : 0x3cu;
}
static void uart_resync(soc_health_providers_t *p)
{
    p->uart.phase = UART_DRAIN;
    p->uart_tx = p->uart_rx = 0u;
    p->uart.deadline.armed = 0u;
}
void soc_health_uart_service(soc_health_core_t *c, soc_health_providers_t *p)
{
    soc_health_transaction_t *t = &p->uart;
    uint32_t i;
    uint8_t byte;
    if (t->phase == UART_INIT) {
        if (uart0_set_baud_div(434u) != UART_RESULT_SUCCESS ||
            uart1_set_baud_div(434u) != UART_RESULT_SUCCESS) {
            fail(c, SOC_IP_UART_LOOP, 0x2001u); return;
        }
        uart_resync(p); return;
    }
    if (!t->deadline.armed) arm(c, p, t);
    if (expired(c, SOC_IP_UART_LOOP, t)) { uart_resync(p); return; }
    if (uart1_rx_error()) {
        fail(c, SOC_IP_UART_LOOP, 0x2002u);
        uart1_clear_rx_error(); uart_resync(p); return;
    }
    if (t->phase == UART_DRAIN) {
        for (i = 0u; i < SOC_HEALTH_UART_RX_QUOTA; i++) {
            if (!uart1_getc_nonblock(&byte)) {
                ++p->uart_seq;
                p->uart_tx = p->uart_rx = 0u;
                arm(c, p, t); t->phase = UART_TRANSFER; return;
            }
        }
        return; /* bounded resync, never drain until empty in one call */
    }
    if (p->uart_tx < 12u && uart0_putc_timeout(
        (char)token_byte(p->uart_seq, p->uart_tx), 1u) == UART_RESULT_SUCCESS)
        p->uart_tx++;
    for (i = 0u; i < SOC_HEALTH_UART_RX_QUOTA; i++) {
        if (!uart1_getc_nonblock(&byte)) break;
        if (byte != token_byte(p->uart_seq, p->uart_rx)) {
            fail(c, SOC_IP_UART_LOOP, 0x21000000u | (p->uart_rx << 8) | byte);
            uart_resync(p); return;
        }
        p->uart_frame[p->uart_rx++] = byte;
        if (p->uart_rx == 12u) {
            if (p->uart_tx != 12u) {
                fail(c, SOC_IP_UART_LOOP, 0x2003u); uart_resync(p); return;
            }
            (void)soc_health_report(c, SOC_IP_UART_LOOP, SOC_STEP_PROGRESS,
                                    p->uart_seq, 434u);
            uart_resync(p); return;
        }
    }
}

void soc_health_gsensor_service(soc_health_core_t *c, soc_health_providers_t *p)
{
    gsensor_sample_t sample;
    gsensor_status_t result;
    if (!p->gsensor.deadline.armed) arm(c, p, &p->gsensor);
    if (expired(c, SOC_IP_GSENSOR, &p->gsensor)) arm(c, p, &p->gsensor);
    result = gsensor_read_sample(&sample);
    if (result == GSENSOR_OK) {
        if (soc_health_report(c, SOC_IP_GSENSOR, SOC_STEP_PROGRESS, sample.seq, 0u))
            arm(c, p, &p->gsensor);
    } else if (result != GSENSOR_NO_NEW && result != GSENSOR_BUSY)
        fail(c, SOC_IP_GSENSOR, 0x3000u | (uint32_t)result);
}

void soc_health_joy_service(soc_health_core_t *c, soc_health_providers_t *p)
{
    joystick_calibration_t cal;
    uint8_t actual, expected;
    if (!p->frame_eligible) return;
    /* Single owner: no CAPTURE/calibration mutation during this read/compare. */
    adc_get_calibration(&cal.center_x, &cal.center_y, &cal.deadzone);
    p->adc_center_x = cal.center_x; p->adc_center_y = cal.center_y;
    p->adc_deadzone = cal.deadzone;
    expected = joystick_policy_eval(&p->frame, &cal);
    actual = adc_get_raw_joy_status();
    if (actual != expected)
        fail(c, SOC_IP_JOY_POLICY, 0x50000000u | ((uint32_t)expected << 8) | actual);
    else if (!soc_health_report(c, SOC_IP_JOY_POLICY, SOC_STEP_PROGRESS,
                                p->frame.seq, ((uint32_t)expected << 8) | actual))
        (void)soc_health_report(c, SOC_IP_JOY_POLICY, SOC_STEP_PENDING,
                                0u, ((uint32_t)expected << 8) | actual);
    /* Same HOLD may be rechecked against current calibration; dedup prevents
     * inventing progress/recovery for an already-qualified generation. */
}

void soc_health_adc_service(soc_health_core_t *c, soc_health_providers_t *p)
{
    soc_health_transaction_t *t = &p->adc;
    adc_status_t result;
    uint32_t count, error, delta;
    if (t->phase == ADC_INIT) {
        if (adc_init() != ADC_OK) {
            fail(c, SOC_IP_ADC, 0x4001u); t->phase = 4u; return;
        }
        adc_get_calibration(&p->adc_center_x, &p->adc_center_y, &p->adc_deadzone);
        p->adc_count = adc_get_frame_count();
        p->adc_error = adc_get_error_status();
        if (p->adc_error) fail(c, SOC_IP_ADC, 0x41000000u | p->adc_error);
        arm(c, p, t); t->phase = ADC_ENABLE; return;
    }
    if (t->phase == 4u) return; /* identity failure requires explicit reinit */
    if (expired(c, SOC_IP_ADC, t)) {
        p->frame_eligible = 0u;
        arm(c, p, t); /* keep request/HOLD/error; never clear merely for PASS */
    }
    if (t->phase == ADC_ENABLE) {
        (void)adc_enable(0u); /* request once; acknowledgement serviced separately */
        t->phase = ADC_WAIT_ENABLE; return;
    }
    if (t->phase == ADC_WAIT_ENABLE) {
        if (adc_is_enabled()) { t->phase = ADC_CAPTURE; arm(c, p, t); }
        return;
    }
    if (!adc_is_enabled()) {
        fail(c, SOC_IP_ADC, 0x4002u); p->frame_eligible = 0u; return;
    }
    error = adc_get_error_status();
    if (error) {
        p->adc_error = error; p->frame_eligible = 0u;
        fail(c, SOC_IP_ADC, 0x41000000u | error); return;
    }
    result = adc_capture(&p->frame);
    if (result == ADC_NO_NEW) return;
    p->frame_eligible = 0u;
    if (result != ADC_OK) { fail(c, SOC_IP_ADC, 0x4000u | (uint32_t)result); return; }
    error = adc_get_error_status(); /* don't miss errors arising during CAPTURE */
    if (error) {
        p->adc_error = error; fail(c, SOC_IP_ADC, 0x41000000u | error); return;
    }
    if ((p->frame.valid_mask & 3u) != 3u) {
        fail(c, SOC_IP_ADC, 0x42000000u | p->frame.valid_mask); return;
    }
    count = adc_get_frame_count(); delta = count - p->adc_count;
    if (delta == 0u || delta >= 0x80000000u) return;
    if (soc_health_report(c, SOC_IP_ADC, SOC_STEP_PROGRESS, p->frame.seq, count)) {
        p->adc_count = count; p->frame_eligible = 1u;
        arm(c, p, t);
        soc_health_joy_service(c, p); /* exact captured generation, before next CAPTURE */
    }
}

void soc_health_vga_service(soc_health_core_t *c, soc_health_providers_t *p)
{
    soc_health_transaction_t *t = &p->vga;
    uint32_t status = vram_status();
    if (!t->deadline.armed) arm(c, p, t);
    if ((status & VRAM_STATUS_OP_ABORT) != 0u) {
        fail(c, SOC_IP_VGA, 0x60000000u | status); /* preserve before W1C */
        vram_clear_events(VRAM_STATUS_OP_ABORT | VRAM_STATUS_OP_DONE | VRAM_STATUS_VSYNC);
        t->phase = VGA_READY; arm(c, p, t); return;
    }
    if (expired(c, SOC_IP_VGA, t)) { t->phase = VGA_READY; return; }
    if ((status & VRAM_STATUS_DOMAIN_READY) == 0u) {
        if (t->phase != VGA_READY) {
            fail(c, SOC_IP_VGA, 0x61000000u | status); t->phase = VGA_READY;
        }
        return;
    }
    switch (t->phase) {
    case VGA_READY:
        if ((status & VRAM_STATUS_OP_BUSY) == 0u) t->phase = VGA_PREPARE;
        break;
    case VGA_PREPARE:
        if ((status & VRAM_STATUS_OP_BUSY) != 0u) break;
        vram_write_word(0u, 0u); /* one deterministic back-bank word, no clear op */
        t->phase = VGA_ARM; break;
    case VGA_ARM:
        vram_clear_events(VRAM_STATUS_VSYNC | VRAM_STATUS_OP_DONE);
        t->phase = VGA_FRESH; break;
    case VGA_FRESH:
        if ((status & VRAM_STATUS_VSYNC) == 0u ||
            (status & VRAM_STATUS_OP_BUSY) != 0u) break;
        /* Recheck ABORT before start_operation clears old events internally. */
        status = vram_status();
        if ((status & VRAM_STATUS_OP_ABORT) != 0u) {
            fail(c, SOC_IP_VGA, 0x60000000u | status); t->phase = VGA_READY; break;
        }
        if (vram_start_operation(VRAM_CTRL_SWAP) != VRAM_RESULT_OK) {
            fail(c, SOC_IP_VGA, 0x62000000u | status); t->phase = VGA_READY; break;
        }
        t->phase = VGA_DONE; break;
    case VGA_DONE:
        if ((status & VRAM_STATUS_OP_DONE) == 0u ||
            (status & VRAM_STATUS_OP_BUSY) != 0u) break;
        (void)soc_health_report(c, SOC_IP_VGA, SOC_STEP_PROGRESS,
                                ++t->generation, status);
        vram_clear_events(VRAM_STATUS_OP_DONE | VRAM_STATUS_VSYNC);
        t->phase = VGA_READY; arm(c, p, t); break;
    default: fail(c, SOC_IP_VGA, 0x6001u); t->phase = VGA_READY; break;
    }
}

soc_ip_id_t soc_health_providers_service(soc_health_core_t *c, soc_health_providers_t *p)
{
    static const soc_ip_id_t init_order[] = {
        SOC_IP_UART_LOOP, SOC_IP_TIMER, SOC_IP_GSENSOR, SOC_IP_ADC, SOC_IP_VGA
    };
    soc_ip_id_t id;
    if (p->init_index < 5u) id = init_order[p->init_index++];
    else {
        id = (soc_ip_id_t)(p->next_provider + 1u);
        if (++p->next_provider == 10u) p->next_provider = 0u;
    }
    p->visits[id]++;
    switch (id) {
    case SOC_IP_TIMER: soc_health_timer_service(c, p); break;
    case SOC_IP_UART_LOOP: soc_health_uart_service(c, p); break;
    case SOC_IP_GSENSOR: soc_health_gsensor_service(c, p); break;
    case SOC_IP_ADC: soc_health_adc_service(c, p); break;
    case SOC_IP_JOY_POLICY: soc_health_joy_service(c, p); break;
    case SOC_IP_VGA: soc_health_vga_service(c, p); break;
    default:
        (void)soc_health_report(c, id, SOC_STEP_PENDING, 0u, SOC_HEALTH_NOT_IMPLEMENTED);
        break;
    }
    return id;
}
