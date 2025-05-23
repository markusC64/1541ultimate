#include "u2p.h"
#include "itu.h"
#include "iomap.h"
#include <stdio.h>

#define W25Q_ContinuousArrayRead_LowFrequency       0x03

#define SPI_FLASH_DATA     *((volatile uint8_t *)(FLASH_BASE + 0x00))
#define SPI_FLASH_DATA_32  *((volatile uint32_t*)(FLASH_BASE + 0x00))
#define SPI_FLASH_CTRL     *((volatile uint8_t *)(FLASH_BASE + 0x08))

#define SPI_FORCE_SS 0x01
#define SPI_LEVEL_SS 0x02
#define BOOT_MAGIC_LOCATION *((volatile uint32_t*)0xFC)
#define BOOT_MAGIC_JUMPADDR *((volatile uint32_t*)0xF8)
#define BOOT_MAGIC_VALUE    (0x1571BABE)

void jump_run(uint32_t a)
{
    void (*function)();
    uint32_t *dp = (uint32_t *)&function;
    *dp = a;
    function();
}

#define APPL "application\n"

void ddr2_calibrate(void);
void hexword(uint32_t);
void hexbyte(uint8_t);
void my_puts(const char *str)
{
    while(*str) {
        outbyte(*(str++));
    }
}

#define MAX_APPL_SIZE 0x140000
#define C1541_IO_LOC_DRIVE_1 ((volatile uint8_t *)DRIVE_A_BASE)
#define C1541_IO_LOC_DRIVE_2 ((volatile uint8_t *)DRIVE_B_BASE)
#define DRIVE1IRQ (*(volatile uint8_t *)(DRIVE_A_BASE + 0x1806))
#define DRIVE2IRQ (*(volatile uint8_t *)(DRIVE_B_BASE + 0x1806))
#define C1541_POWER       0
#define C1541_RESET       1

int main()
{
    uint32_t capabilities = getFpgaCapabilities();
    hexword(capabilities);

	if (capabilities & CAPAB_SIMULATION) {
		jump_run(0x30000);
	}

    // It is REQUIRED to pull the drive resets to zero for a moment
    // because the primary net is buggy.
    hexbyte(C1541_IO_LOC_DRIVE_1[C1541_RESET]);
    hexbyte(C1541_IO_LOC_DRIVE_2[C1541_RESET]);
    outbyte(':');
    hexbyte(DRIVE1IRQ);
    hexbyte(DRIVE2IRQ);
    outbyte('^');
    C1541_IO_LOC_DRIVE_1[C1541_RESET] = 0;
    C1541_IO_LOC_DRIVE_2[C1541_RESET] = 0;
    hexbyte(DRIVE1IRQ);
    hexbyte(DRIVE2IRQ);
    outbyte('^');
    C1541_IO_LOC_DRIVE_1[C1541_RESET] = 7;
    C1541_IO_LOC_DRIVE_2[C1541_RESET] = 7;
    hexbyte(DRIVE1IRQ);
    hexbyte(DRIVE2IRQ);
    outbyte('^');

    if(capabilities) { // only TESTER has zero as capabilities. Tester doesn't have DDR2
        outbyte('#');
        ddr2_calibrate();
    } else {
        my_puts("Tester Module.\n");
    }

    capabilities = getFpgaCapabilities();
    hexword(capabilities);

    if (capabilities > 1) {
        uint32_t flash_addr = 0xA0000; // 640K from start. FPGA image is (uncompressed) 571K
        
        SPI_FLASH_CTRL = SPI_FORCE_SS; // drive CSn low
        SPI_FLASH_DATA = W25Q_ContinuousArrayRead_LowFrequency;
        SPI_FLASH_DATA = (uint8_t)(flash_addr >> 16);
        SPI_FLASH_DATA = (uint8_t)(flash_addr >> 8);
        SPI_FLASH_DATA = (uint8_t)(flash_addr);

        uint32_t *dest   = (uint32_t *)SPI_FLASH_DATA_32;
        int      length  = (int)SPI_FLASH_DATA_32;
        uint32_t run_address = SPI_FLASH_DATA_32;

        hexword((uint32_t)dest);
        hexword((uint32_t)length);
        hexword(run_address);

    #if NO_BOOT == 1
        my_puts("Waiting for JTAG download!\n\n");
        while(1) {
            ioWrite8(ITU_SD_BUSY, 1);
            ioWrite8(ITU_SD_BUSY, 0);
        }
    //    uint32_t version = SPI_FLASH_DATA_32;
    #else
        my_puts(APPL);

        if(length != -1) {
            while ((length > 0) && (length < MAX_APPL_SIZE)) {
                *(dest++) = SPI_FLASH_DATA_32;
                length -= 4;
            }
            SPI_FLASH_CTRL = 0; // reset SPI chip select to idle
            my_puts("Running\n");
            uint8_t buttons = ioRead8(ITU_BUTTON_REG) & ITU_BUTTONS;
            if ((buttons & ITU_BUTTON2) == 0) {  // right button not pressed
                jump_run(run_address);
            } else {
                my_puts("Lock\n");
            }
            while(1) {
                __asm__("nop");
                __asm__("nop");
            }
        }
    #endif
    } else if(BOOT_MAGIC_LOCATION == BOOT_MAGIC_VALUE) {
        my_puts("Magic!\n");
        BOOT_MAGIC_LOCATION = 0;
        jump_run(BOOT_MAGIC_JUMPADDR);
    }

    my_puts("Empty\n");
    while(1) {
        __asm__("nop");
        __asm__("nop");
    }
    return 0;
}
