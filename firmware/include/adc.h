#ifndef ADC_H
#define ADC_H

#include <stdint.h>
#include <stdbool.h>
#include "soc_memory_map.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Coherent ADC HOLD generation snapshot */
typedef struct {
    uint32_t seq;
    uint8_t  valid_mask;
    uint16_t ch[6];
} adc_frame_t;

/* Standard ADC Driver Status Codes */
typedef enum {
    ADC_OK            = 0,
    ADC_NO_NEW        = 1,
    ADC_TIMEOUT       = 2,
    ADC_ERROR         = 3,
    ADC_INVALID_PARAM = 4
} adc_status_t;

/**
 * Initializes the ADC peripheral driver:
 *   - Verifies peripheral identity registers (NAME0="ADC_", NAME1="_v2\0").
 *   - Reads initial enable state from hardware.
 * Returns ADC_OK on success, ADC_ERROR if peripheral ID check fails.
 */
adc_status_t adc_init(void);

/**
 * Requests acquisition engine enable and polls for engine acknowledgement.
 * Bounded by timeout_loops.
 */
adc_status_t adc_enable(uint32_t timeout_loops);

/**
 * Requests acquisition engine disable and polls for engine quiesce acknowledgement.
 * Bounded by timeout_loops.
 */
adc_status_t adc_disable(uint32_t timeout_loops);

/**
 * Returns true if the acquisition engine has completed enablement (ENGINE_ENABLED=1).
 */
bool adc_is_enabled(void);

/**
 * Coherent capture sequence:
 *   1. Polls ADC_STATUS for NEW_FRAME. If 0, returns ADC_NO_NEW.
 *   2. Writes ADC_CTRL with persistent ENABLE level | ADC_CTRL_CAPTURE.
 *   3. Reads HOLD bank (FRAME_SEQ, VALID_MASK, CH1..CH6).
 *   4. Populates frame struct and returns ADC_OK.
 * Never returns stale HOLD data as new.
 */
adc_status_t adc_capture(adc_frame_t *frame);

/**
 * Reads the current HOLD bank without issuing a new CAPTURE command.
 * Returns ADC_NO_NEW if HOLD_VALID is not asserted.
 */
adc_status_t adc_read_hold(adc_frame_t *frame);

/**
 * Writes joystick calibration registers (CENTER_X, CENTER_Y, DEADZONE).
 * Updates live hardware policy immediately without triggering CAPTURE.
 */
void adc_set_calibration(uint16_t center_x, uint16_t center_y, uint16_t deadzone);

/**
 * Reads back current joystick calibration registers.
 */
void adc_get_calibration(uint16_t *center_x, uint16_t *center_y, uint16_t *deadzone);

/**
 * Reads hardware JOY_STATUS (0x4C) for observation/debug.
 */
uint8_t adc_get_raw_joy_status(void);

/**
 * Reads sticky ADC_ERROR_STATUS (0x64).
 */
uint32_t adc_get_error_status(void);

/**
 * Clears sticky error bits using W1P CLEAR_ERROR while preserving ENABLE level.
 */
void adc_clear_error(void);

/**
 * Reads total published frame count counter (0x60).
 */
uint32_t adc_get_frame_count(void);

/**
 * Reads raw peripheral status register (0x10).
 */
uint32_t adc_get_status(void);

#ifdef __cplusplus
}
#endif

#endif /* ADC_H */
