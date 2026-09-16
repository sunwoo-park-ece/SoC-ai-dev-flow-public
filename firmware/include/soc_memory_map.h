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
#define JOYSTICK_BASE        0x40050000u
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

#define JOY_CTRL             0x0cu
#define JOY_STATUS           0x10u
#define JOY_X_CHANNEL        0x14u
#define JOY_Y_CHANNEL        0x18u
#define JOY_X_RAW            0x1cu
#define JOY_Y_RAW            0x20u
#define JOY_CENTER_X         0x24u
#define JOY_CENTER_Y         0x28u
#define JOY_DEADZONE         0x2cu
#define JOY_DIR_STATUS       0x30u
#define JOY_SAMPLE_COUNT     0x34u

#define VRAM_STATUS          0x10000u
#define VRAM_CONTROL         0x10004u

#endif
