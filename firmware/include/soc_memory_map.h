#ifndef SOC_MEMORY_MAP_H
#define SOC_MEMORY_MAP_H

#define SOC_IMEM_BASE        0x00000000u
#define SOC_IMEM_SIZE        0x00004000u
#define SOC_DMEM_BASE        0x10000000u
#define SOC_DMEM_SIZE        0x00008000u

#define VRAM_BASE            0x20000000u
#define UART0_BASE           0x40000000u
#define GPIO_BASE            0x40010000u
#define TIMER_BASE           0x40020000u
#define GSENSOR_BASE         0x40030000u
#define AES_GCM_BASE         0x40040000u
#define ADC_BASE             0x40050000u
#define JOYSTICK_BASE        ADC_BASE /* DEPRECATED transitional alias; use ADC_BASE */
#define UART1_BASE           0x40060000u
#define HEX_DISPLAY_BASE     0x40070000u
#define SW_BASE              0x40080000u
#define LED_BASE             0x40090000u

#define UART_DATA            0x00u
#define UART_STATUS          0x04u
#define UART_CONTROL         0x08u
#define UART_BAUD            0x0cu

#define GPIO_DATA_IN         0x00u
#define GPIO_DATA_OUT        0x04u
#define GPIO_DIR             0x08u
#define GPIO_IRQ_ENABLE      0x0cu
#define GPIO_IRQ_TYPE        0x10u
#define GPIO_IRQ_POLARITY    0x14u
#define GPIO_IRQ_BOTH_EDGE   0x18u
#define GPIO_IRQ_PENDING     0x1cu

#define SW_DATA              0x00u
#define SW_IRQ_ENABLE        0x04u
#define SW_IRQ_PENDING       0x08u
#define LED_DATA             0x00u

#define TIMER_CTRL           0x00u
#define TIMER_COUNT          0x04u
#define TIMER_COMPARE        0x08u
#define TIMER_STATUS         0x0cu

#define HEX_VALUE            0x00u
#define HEX_CTRL             0x04u
#define HEX_RAW_LOW          0x08u
#define HEX_RAW_HIGH         0x0cu

#define AES_CTRL             0x0cu
#define AES_STATUS           0x10u
#define AES_KEY0             0x20u
#define AES_NONCE_DIR        0x30u
#define AES_SEQ_HI           0x34u
#define AES_SEQ_LO           0x38u
#define AES_LEN              0x3cu
#define AES_PAYLOAD_IN0      0x40u
#define AES_TAG_IN0          0x50u
#define AES_PAYLOAD_OUT0     0x60u
#define AES_TAG_OUT0         0x70u

/* ========================================================================= */
/* Generic ADC Peripheral v2 Registers (ADC_BASE = 0x40050000u)              */
/* ========================================================================= */
#define ADC_NAME0            0x00u
#define ADC_NAME1            0x04u
#define ADC_VERSION          0x08u
#define ADC_CTRL             0x0cu
#define ADC_STATUS           0x10u
#define ADC_FRAME_SEQ        0x14u
#define ADC_VALID_MASK       0x18u
#define ADC_CH1_RAW          0x1cu
#define ADC_CH2_RAW          0x20u
#define ADC_CH3_RAW          0x24u
#define ADC_CH4_RAW          0x28u
#define ADC_CH5_RAW          0x2cu
#define ADC_CH6_RAW          0x30u
#define ADC_LIVE_SEQ         0x34u
#define ADC_LIVE_VALID_MASK  0x38u
#define ADC_ACTIVE_MASK      0x3cu
#define ADC_JOY_CENTER_X     0x40u
#define ADC_JOY_CENTER_Y     0x44u
#define ADC_JOY_DEADZONE     0x48u
#define ADC_JOY_STATUS       0x4cu
#define ADC_FRAME_COUNT      0x60u
#define ADC_ERROR_STATUS     0x64u

/* ADC_CTRL bitfields */
#define ADC_CTRL_ENABLE       (1u << 0)
#define ADC_CTRL_CAPTURE      (1u << 1)
#define ADC_CTRL_CLEAR_ERROR  (1u << 2)

/* ADC_STATUS bitfields */
#define ADC_STATUS_ENABLE_REQ     (1u << 0)
#define ADC_STATUS_ENGINE_ENABLED (1u << 1)
#define ADC_STATUS_LIVE_VALID     (1u << 2)
#define ADC_STATUS_HOLD_VALID     (1u << 3)
#define ADC_STATUS_NEW_FRAME      (1u << 4)
#define ADC_STATUS_MAILBOX_BUSY   (1u << 5)
/* bit 6: strictly RESERVED / 0 */
#define ADC_STATUS_ERROR_PENDING  (1u << 7)

/* ADC_JOY_STATUS bitfields */
#define ADC_JOY_FORWARD       (1u << 0)
#define ADC_JOY_BACKWARD      (1u << 1)
#define ADC_JOY_LEFT          (1u << 2)
#define ADC_JOY_RIGHT         (1u << 3)
#define ADC_JOY_X_VALID       (1u << 4)
#define ADC_JOY_Y_VALID       (1u << 5)

/* ADC_ERROR_STATUS bitfields */
#define ADC_ERROR_UNEXPECTED_CHANNEL (1u << 0)
#define ADC_ERROR_DUPLICATE_CHANNEL  (1u << 1)
#define ADC_ERROR_ORDER_ERROR        (1u << 2)
#define ADC_ERROR_PACKET_ERROR       (1u << 3)

#define VRAM_STATUS          0x10000u
#define VRAM_CONTROL         0x10004u

#endif
