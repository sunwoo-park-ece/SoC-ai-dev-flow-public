/* Linker Script for RV32I46F_5SP Processor */
/* Memory Map:
* <MMIO address_map>
* IMEM(ROM)   : 0x0000_0000, 16KB
* DMEM(RAM)   : 0x1000_0000, 32KB (0:8191)
* VRAM        : 0x2000_0000, (~0x2FFF_FFFF)
* UART[0]     : 0x4000_0000,
* GPIO[1]     : 0x4001_0000,  // 현재 input: SW, output: LEDR
* 타이머[2]   : 0x4002_0000, 
* 가속도계[3] : 0x4003_0000,
* AES-GCM[4]  : 0x4004_0000
* JOYSTICK[5] : 0x4005_0000
*/
/* 선우님의 SoC 주소 맵 반영 */
/* **상수데이터**와 **초기값이 있는 변수** 모두 RAM 영역에 저장함
 * FGPA의 장점
*/
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    DMEM (rwx) : ORIGIN = 0x10000000, LENGTH = 32K
}

SECTIONS
{
    /* 1. 명령어 코드 (ROM에 배치) */
    . = ORIGIN(IMEM);
    .imem : ALIGN(4)
    {
        KEEP(*(.start))
        *(.text*)
        *(.init*)
        *(.fini*)
    } > IMEM

    /* 2. 상수 데이터 (RAM 시작 주소에 배치) */
    /* 3. 초기값이 있는 변수 (RAM에 배치, 초기화는 Quartus .mif가 수행) */
    . = ORIGIN(DMEM);
    .dmem_init : ALIGN(4)
    {
        *(.rodata*)
        *(.srodata*)
        *(.data*)
        *(.sdata*)
    } > DMEM

    /* 4. 초기값이 없는 변수 (RAM에 배치, startup.s가 0으로 초기화) */
    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > DMEM

     /* 스택 포인터: RAM의 맨 끝 -4 */
    . = ORIGIN(DMEM) + LENGTH(DMEM) - 4;
    __stack_top = .;

    /DISCARD/ :
    {
        *(.eh_frame*)
        *(.comment*)
        *(.riscv.attributes*)
    }
}
