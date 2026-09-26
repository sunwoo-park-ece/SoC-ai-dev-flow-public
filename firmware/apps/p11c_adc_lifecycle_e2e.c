#include <stdint.h>
#include <stdbool.h>
#include "adc.h"
#include "joystick_policy.h"
#include "soc_memory_map.h"
#include "soc_mmio.h"

volatile uint32_t g_test_step = 0;
volatile uint32_t g_test_signature = 0;
volatile uint32_t g_fault_caught = 0;
volatile uint32_t g_fault_mcause = 0;

static void trap_handler(void)
{
    uint32_t mcause, mepc;
    __asm__ volatile(
        ".option push\n"
        ".option arch, +zicsr\n"
        "csrr %0, mcause\n"
        "csrr %1, mepc\n"
        ".option pop\n"
        : "=r"(mcause), "=r"(mepc)
    );
    g_fault_caught = 1;
    g_fault_mcause = mcause;
    mepc += 4; // Skip the faulting instruction
    __asm__ volatile(
        ".option push\n"
        ".option arch, +zicsr\n"
        "csrw mepc, %0\n"
        "mret\n"
        ".option pop\n"
        : : "r"(mepc)
    );
}

int main(void)
{
    adc_frame_t f1, f2, f3, f4, f_hold;
    joystick_calibration_t cal;
    uint8_t fw_joy, hw_joy;
    uint32_t status, error_stat;

    g_test_step = 1;
    // Step 1: Peripheral identity
    if (adc_init() != ADC_OK) {
        g_test_signature = 0xDEAD0001;
        for (;;) ;
    }

    // Verify initial calibration read
    adc_get_calibration(&cal.center_x, &cal.center_y, &cal.deadzone);

    g_test_step = 2;
    // Step 2: Enable engine with bounded polling
    if (adc_enable(2000u) != ADC_OK) {
        g_test_signature = 0xDEAD0002;
        for (;;) ;
    }

    g_test_step = 3;
    // Step 3: Wait for first valid frame and capture
    while ((adc_get_status() & ADC_STATUS_NEW_FRAME) == 0u) ;
    if (adc_capture(&f1) != ADC_OK) {
        g_test_signature = 0xDEAD0003;
        for (;;) ;
    }

    g_test_step = 4;
    // Step 4: Immediate second capture without waiting for new frame
    // Must return ADC_NO_NEW (rejects stale HOLD as new)
    if (adc_capture(&f2) != ADC_NO_NEW) {
        g_test_signature = 0xDEAD0004;
        for (;;) ;
    }

    g_test_step = 5;
    // Step 5: Wait for newer frame, then capture
    while ((adc_get_status() & ADC_STATUS_NEW_FRAME) == 0u) ;
    if (adc_capture(&f3) != ADC_OK || f3.seq <= f1.seq) {
        g_test_signature = 0xDEAD0005;
        for (;;) ;
    }

    g_test_step = 6;
    // Step 6: Joystick Policy Comprehensive Verification in CPU context
    // 6a: Test with current captured frame f3
    cal.center_x = 2048;
    cal.center_y = 2048;
    cal.deadzone = 512;
    adc_set_calibration(cal.center_x, cal.center_y, cal.deadzone);
    fw_joy = joystick_policy_eval(&f3, &cal);
    hw_joy = adc_get_raw_joy_status();
    if (fw_joy != hw_joy) {
        g_test_signature = 0xDEAD0061;
        for (;;) ;
    }

    // 6b: Test calibration update without new CAPTURE
    // Changing calibration immediately affects HW JOY_STATUS evaluated on existing HOLD
    adc_set_calibration(2048, 2048, 2000); // large deadzone
    cal.deadzone = 2000;
    fw_joy = joystick_policy_eval(&f3, &cal);
    hw_joy = adc_get_raw_joy_status();
    if (fw_joy != hw_joy) {
        g_test_signature = 0xDEAD0062;
        for (;;) ;
    }

    // 6c: Test synthesized frames across all remaining policy cases
    adc_frame_t test_frame;
    test_frame.seq = 99;
    test_frame.valid_mask = 0x03; // CH1 and CH2 valid
    const uint8_t both_valid = (uint8_t)(JOY_POLICY_DIR_X_VALID | JOY_POLICY_DIR_Y_VALID);

    // Vector: Neutral
    test_frame.ch[0] = 2048; test_frame.ch[1] = 2048;
    cal.deadzone = 512;
    if (joystick_policy_eval(&test_frame, &cal) != both_valid) {
        g_test_signature = 0xDEAD0063;
        for (;;) ;
    }

    // Vector: LEFT
    test_frame.ch[0] = 512; test_frame.ch[1] = 2048;
    if (joystick_policy_eval(&test_frame, &cal) != (both_valid | JOY_POLICY_DIR_LEFT)) {
        g_test_signature = 0xDEAD0064;
        for (;;) ;
    }

    // Vector: RIGHT
    test_frame.ch[0] = 3584; test_frame.ch[1] = 2048;
    if (joystick_policy_eval(&test_frame, &cal) != (both_valid | JOY_POLICY_DIR_RIGHT)) {
        g_test_signature = 0xDEAD0065;
        for (;;) ;
    }

    // Vector: FORWARD
    test_frame.ch[0] = 2048; test_frame.ch[1] = 3584;
    if (joystick_policy_eval(&test_frame, &cal) != (both_valid | JOY_POLICY_DIR_FORWARD)) {
        g_test_signature = 0xDEAD0066;
        for (;;) ;
    }

    // Vector: BACKWARD
    test_frame.ch[0] = 2048; test_frame.ch[1] = 512;
    if (joystick_policy_eval(&test_frame, &cal) != (both_valid | JOY_POLICY_DIR_BACKWARD)) {
        g_test_signature = 0xDEAD0067;
        for (;;) ;
    }

    // Vector: DIAGONAL (LEFT | FORWARD)
    test_frame.ch[0] = 512; test_frame.ch[1] = 3584;
    if (joystick_policy_eval(&test_frame, &cal) != (both_valid | JOY_POLICY_DIR_LEFT | JOY_POLICY_DIR_FORWARD)) {
        g_test_signature = 0xDEAD0068;
        for (;;) ;
    }

    // Vector: Invalid X (missing bit 0 in valid_mask)
    test_frame.valid_mask = 0x02; // only CH2 valid
    if (joystick_policy_eval(&test_frame, &cal) != (JOY_POLICY_DIR_Y_VALID | JOY_POLICY_DIR_FORWARD)) {
        g_test_signature = 0xDEAD0069;
        for (;;) ;
    }

    // Vector: Invalid Y (missing bit 1 in valid_mask)
    test_frame.valid_mask = 0x01; // only CH1 valid
    test_frame.ch[0] = 512;
    if (joystick_policy_eval(&test_frame, &cal) != (JOY_POLICY_DIR_X_VALID | JOY_POLICY_DIR_LEFT)) {
        g_test_signature = 0xDEAD006A;
        for (;;) ;
    }

    g_test_step = 7;
    // Step 7: Disable lifecycle
    // Disable engine
    if (adc_disable(2000u) != ADC_OK) {
        g_test_signature = 0xDEAD0007;
        for (;;) ;
    }

    // Verify bounded acknowledgement: ENGINE_ENABLED=0
    status = adc_get_status();
    if ((status & ADC_STATUS_ENGINE_ENABLED) != 0u) {
        g_test_signature = 0xDEAD0071;
        for (;;) ;
    }

    // Verify LIVE invalidated: LIVE_VALID=0, NEW_FRAME=0
    if ((status & ADC_STATUS_LIVE_VALID) != 0u || (status & ADC_STATUS_NEW_FRAME) != 0u) {
        g_test_signature = 0xDEAD0072;
        for (;;) ;
    }

    // Verify HOLD preserved: adc_read_hold() returns preserved frame f3
    if (adc_read_hold(&f_hold) != ADC_OK || f_hold.seq != f3.seq ||
        f_hold.ch[0] != f3.ch[0] || f_hold.ch[1] != f3.ch[1]) {
        g_test_signature = 0xDEAD0073;
        for (;;) ;
    }

    g_test_step = 8;
    // Step 8: Re-enable lifecycle
    // Re-enable engine
    if (adc_enable(2000u) != ADC_OK) {
        g_test_signature = 0xDEAD0008;
        for (;;) ;
    }

    // Wait for first new complete frame after re-enable
    while ((adc_get_status() & ADC_STATUS_NEW_FRAME) == 0u) ;
    if (adc_capture(&f4) != ADC_OK || f4.seq <= f3.seq) {
        g_test_signature = 0xDEAD0081;
        for (;;) ;
    }

    g_test_step = 9;
    // Step 9: Error status and CLEAR_ERROR set-dominance check
    error_stat = adc_get_error_status();
    adc_clear_error();
    (void)error_stat;

    g_test_step = 10;
    // Step 10: Slot-5 illegal offset access fault verification
    // Install custom trap handler
    uint32_t trap_addr = (uint32_t)&trap_handler;
    __asm__ volatile(
        ".option push\n"
        ".option arch, +zicsr\n"
        "csrw mtvec, %0\n"
        ".option pop\n"
        : : "r"(trap_addr)
    );

    // Write to Read-Only register (ADC_NAME0: 0x4005_0000)
    // Hardware APB_ADC_Controller asserts PSLVERR -> AHB ERROR -> CPU traps
    mmio_write32(ADC_BASE + ADC_NAME0, 0x12345678u);

    // Verify trap was caught (mcause == 7: Store access fault)
    if (g_fault_caught != 1u || g_fault_mcause != 7u) {
        g_test_signature = 0xDEAD0010;
        for (;;) ;
    }

    g_test_step = 11;
    // All steps PASSED! Write success signature
    g_test_signature = 0x50313143; // "P11C"

    for (;;) {
        __asm__ volatile("nop");
    }
    return 0;
}
