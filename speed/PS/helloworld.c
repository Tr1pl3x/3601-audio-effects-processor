/******************************************************************************
* Copyright (C) 2023 Advanced Micro Devices, Inc. All Rights Reserved.
* SPDX-License-Identifier: MIT
******************************************************************************/
/*
 * helloworld.c: simple test application
 *
 * This application configures UART 16550 to baud rate 9600.
 * PS7 UART (Zynq) is not initialized by this application, since
 * bootrom/bsp configures it to baud rate 115200
 *
 * ------------------------------------------------
 * | UART TYPE   BAUD RATE                        |
 * ------------------------------------------------
 *   uartns550   9600
 *   uartlite    Configurable only in HW design
 *   ps7_uart    115200 (configured by bootrom/bsp)
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#include "platform.h"
#include "xil_printf.h"
#include "xaxidma.h"
#include "sleep.h"
#include "ff.h"
#include "xsdps.h"
#include "xparameters.h"
#include "xil_io.h"
#include "xil_cache.h"

#define BUF_SIZE 1440768 //48000 * 30
#define BATCH_SIZE 1024

//volatile char tx_buf[BUF_SIZE] = {}; //not needed
volatile uint32_t rx_buf[BUF_SIZE] = {};

//for sd
static FIL fil;
static FATFS fatfs;
MKFS_PARM mkfs_parm;

//constants
#define SAMPLE_SIZE 32
#define SAMPLE_PMC 18
#define EXTRA_BITS SAMPLE_SIZE - SAMPLE_PMC
#define SAMPLE_RATE 48000

//Audio pipeline control registers
//Base address from xparameters.h: XPAR_AUDIO_PIPELINE_0_BASEADDR
#define AUDIO_PIPELINE_BASEADDR XPAR_AUDIO_PIPELINE_0_BASEADDR  // 0xA0000000
#define CONTROL_REG_OFFSET 0x00  // slv_reg0 at offset 0x00 (effect selector in bits [2:0])
#define GAIN_REG_OFFSET 0x0C  // slv_reg3 at offset 0x0C
#define SPEED_REG_OFFSET 0x10  /* slv_reg4£ºspeed_mode Bits[1:0] */

//Gain values in Q16.16 fixed-point format
//Format: 16 integer bits + 16 fractional bits
#define GAIN_MUTE    0x00000000  // 0.0x - Mute
#define GAIN_HALF    0x00008000  // 0.5x - Half volume
#define GAIN_UNITY   0x00010000  // 1.0x - No change (default)
#define GAIN_1_5X    0x00018000  // 1.5x - 50% boost
#define GAIN_2X      0x00020000  // 2.0x - Double volume
#define GAIN_4X      0x00040000  // 4.0x - Quadruple volume
#define GAIN_8X      0x00080000  // 8.0x - 8x boost (may clip/saturate)

/* Speed mode (match speed_effect.vhd) : speed_reg[1:0] */
#define SPEED_NORMAL 0x0  /* "00": 1.0x pass through */
#define SPEED_X2     0x1  /* "01": 2.0x discard every other sample*/
#define SPEED_HALF   0x2  /* "10": 0.5x linear interpolation */

//Effect selector values (3-bit values for bits [2:0] of control register)
//These correspond to the effect MUX in audio_effects.vhd
#define EFFECT_NONE       0  // 000: Bypass - no processing
#define EFFECT_ECHO       1  // 001: Echo effect (to be implemented by Morris)
#define EFFECT_GAIN       2  // 010: Gain/volume control
#define EFFECT_SPEED      3  // 011: Speed up/slow down (to be implemented by Jiatong)
#define EFFECT_CLIPPING   4  // 100: Clipping (to be implemented by Ayush)
#define EFFECT_FLANGER    5  // 101: Flanger (to be implemented by Alexandra)

// Choose initial demo settings
#define INITIAL_EFFECT     EFFECT_SPEED
#define INITIAL_GAIN_Q16   GAIN_UNITY
#define INITIAL_SPEED_MODE SPEED_NORMAL

//Effect names for display (matches the order above)
const char *effect_names[] = {
    "None (Bypass)",
    "Echo",
    "Gain",
    "Speed",
    "Clipping",
    "Flanger"
};

// ============================================
// GAIN CONFIGURATION - Change this value to adjust audio volume
// ============================================
// Options: GAIN_MUTE, GAIN_HALF, GAIN_UNITY, GAIN_1_5X, GAIN_2X, GAIN_4X, GAIN_8X
// Or use custom value: (uint32_t)(desired_gain * 65536)
// Examples:
//   - For 10x gain: (uint32_t)(10.0 * 65536)
//   - For 0.25x gain: (uint32_t)(0.25 * 65536)
//   - For 16x gain: (uint32_t)(16.0 * 65536)
const uint32_t AUDIO_GAIN = GAIN_4X;  // <<< CHANGE THIS VALUE TO ADJUST GAIN

//wav file header
//http://soundfile.sapp.org/doc/WaveFormat/
typedef struct {
    char chunkID[4];        // "RIFF"
    uint32_t chunkSize;  	// 36 + data size
    char format[4];         // "WAVE"
    char subChunk1ID[4];    // "fmt "
    uint32_t subchunk1Size; // 16
    uint16_t audioFormat;   // 1 = PCM
    uint16_t numChannels;   // 1 or 2
    uint32_t sampleRate;    // e.g., 48000
    uint32_t byteRate;      // sampleRate * numChannels * bitsPerSample/8
    uint16_t blockAlign;    // numChannels * bitsPerSample/8
    uint16_t bitsPerSample; // bits per sample (precision)
    char subchunk2ID [4];   // "data"
    uint32_t subchunk2Size;      // bytes of PCM data
} WAVHeader;

/**
 * Set the audio gain via memory-mapped register write
 * @param gain_value: Q16.16 fixed-point gain coefficient
 *                    Use predefined constants (GAIN_MUTE, GAIN_UNITY, etc.)
 *                    or calculate custom value: (int)(desired_gain * 65536)
 *
 * Example usage:
 *   set_audio_gain(GAIN_UNITY);   // 1.0x gain (no change)
 *   set_audio_gain(GAIN_HALF);    // 0.5x gain (reduce volume)
 *   set_audio_gain(GAIN_2X);      // 2.0x gain (double volume)
 */
void set_audio_gain(uint32_t gain_value) {
    // Write to gain register via AXI4-Lite
    Xil_Out32(AUDIO_PIPELINE_BASEADDR + GAIN_REG_OFFSET, gain_value);
    xil_printf("Gain set to 0x%08X (", gain_value);

    // Print human-readable gain value
    float gain_float = (float)gain_value / 65536.0f;
    xil_printf("%.2fx)\r\n", gain_float);
}

/**
 * Read current gain setting from hardware register
 * @return current gain value in Q16.16 format
 */
uint32_t get_audio_gain(void) {
    return Xil_In32(AUDIO_PIPELINE_BASEADDR + GAIN_REG_OFFSET);
}

/**
 * Set the active audio effect via memory-mapped register write
 * @param effect_id: Effect selector value (0-5)
 *                   Use predefined constants (EFFECT_NONE, EFFECT_ECHO, etc.)
 *
 * Effect IDs:
 *   0 = None (Bypass)
 *   1 = Echo
 *   2 = Gain
 *   3 = Speed up/down
 *   4 = Clipping
 *   5 = Flanger
 *
 * Example usage:
 *   set_audio_effect(EFFECT_GAIN);    // Enable gain effect
 *   set_audio_effect(EFFECT_NONE);    // Bypass all effects
 *   set_audio_effect(EFFECT_ECHO);    // Enable echo effect
 */
void set_audio_effect(uint8_t effect_id) {
    // Ensure effect_id is in valid range (0-5)
    if (effect_id > 5) {
        xil_printf("Invalid effect ID: %d. Must be 0-5.\r\n", effect_id);
        return;
    }

    // Read current control register value
    uint32_t control_reg = Xil_In32(AUDIO_PIPELINE_BASEADDR + CONTROL_REG_OFFSET);

    // Clear bits [2:0] and set new effect selector
    control_reg = (control_reg & 0xFFFFFFF8) | (effect_id & 0x07);

    // Write back to control register
    Xil_Out32(AUDIO_PIPELINE_BASEADDR + CONTROL_REG_OFFSET, control_reg);

    xil_printf("Effect changed to: %s (ID=%d)\r\n", effect_names[effect_id], effect_id);
}

/**
 * Read current effect selection from hardware register
 * @return current effect ID (0-5)
 */
uint8_t get_audio_effect(void) {
    uint32_t control_reg = Xil_In32(AUDIO_PIPELINE_BASEADDR + CONTROL_REG_OFFSET);
    return (uint8_t)(control_reg & 0x07);  // Extract bits [2:0]
}

void set_speed_mode(uint32_t mode2b) {
    // only use bit[1:0]
    uint32_t val = (mode2b & 0x3u);
    Xil_Out32(AUDIO_PIPELINE_BASEADDR + SPEED_REG_OFFSET, val);
    const char *mname =
        (val == SPEED_NORMAL) ? "NORMAL 1.0x" :
        (val == SPEED_X2)     ? "X2 (faster)" :
        (val == SPEED_HALF)   ? "X0.5 (slower)" : "UNKNOWN";
    xil_printf("Speed mode -> 0x%08X (%s)\r\n", val, mname);
}

uint32_t get_speed_mode(void) {
    return (Xil_In32(AUDIO_PIPELINE_BASEADDR + SPEED_REG_OFFSET) & 0x3u);
}

/**
 * Cycle to the next effect in the sequence
 * Effect cycle: None -> Echo -> Gain -> Speed -> Clipping -> Flanger -> (repeat)
 *
 * This function is designed to be called from a button press interrupt handler
 */
void cycle_to_next_effect(void) {
    uint8_t current_effect = get_audio_effect();
    uint8_t next_effect = (current_effect + 1) % 6;  // Cycle 0->1->2->3->4->5->0
    set_audio_effect(next_effect);
}

void dma() {
	//declare necessary variables
	int Status = XST_SUCCESS;
	XAxiDma_Config *CfgPtr;
	XAxiDma AxiDma;

	//no scatter-gather
	CfgPtr = XAxiDma_LookupConfig(XPAR_AXI_DMA_0_DEVICE_ID);
	if (!CfgPtr) {
		print("No CfgPtr");
	    return;
	}

	Status = XAxiDma_CfgInitialize(&AxiDma, CfgPtr);
	    if (Status != XST_SUCCESS) {
	        print("DMA cfg init failure");
	        return;
	   }

	   if (XAxiDma_HasSg(&AxiDma)) {
	       print("Device configured as SG mode \r\n");
	       return;
	   }

	   print("DMA initialised\r\n");

	   //self test to check if it is configured properly
	   Status = XAxiDma_Selftest(&AxiDma);
	   if (Status != XST_SUCCESS) {
	         print("DMA failed selftest\r\n");
	         return ;
	    }
	    print("DMA passed self test\r\n");

	    //polling rather than interrupts
	    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK,
	    XAXIDMA_DEVICE_TO_DMA);
	    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK,
	    XAXIDMA_DMA_TO_DEVICE);

	    //READ
	    for (int i = 0; i < BUF_SIZE / BATCH_SIZE; i++) {
	    	Xil_DCacheFlushRange((UINTPTR)(rx_buf + i * BATCH_SIZE), BATCH_SIZE * 4);
	    	//sleep(5); //maybe remove

	    	//read from DMA
	    	Status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR) (rx_buf + i * BATCH_SIZE),
	    		BATCH_SIZE * 4, XAXIDMA_DEVICE_TO_DMA);

	    	if (Status != XST_SUCCESS) {
	    	            print("failed rx transfer call\r\n");
	    	}
	    	else {
	    		//print("dma read success\r\n");
	    	}

	    	while (XAxiDma_Busy(&AxiDma, XAXIDMA_DEVICE_TO_DMA)) {
	    	}
	    	//print("DMA read completed\r\n");

	    	//flush
	    	//invalidate instead of flush
	    	Xil_DCacheFlushRange((UINTPTR)(rx_buf + i * BATCH_SIZE), BATCH_SIZE * 4);
	    }

	    print("DMA done\r\n");

}

void sd_write(volatile uint32_t *buf, int buf_size, char *name) {
	FRESULT res;
	xil_printf("Attempting to open file: %s\n", name);
	res = f_open(&fil, name, FA_CREATE_ALWAYS | FA_WRITE);
	xil_printf("f_open returned: %d\n", res);
	unsigned int br;
	if(res != FR_OK)
	  {
		xil_printf("file creation failed, FRESULT=%d\n", res);
		print("file creation failed\n");
	    return ;
	  }
	print("File opened successfully\n");

	res = f_lseek(&fil, 0);
	if (res) {
		return;
	}

	//HEADER
	WAVHeader header;
	memcpy(header.chunkID, "RIFF", 4);
	memcpy(header.format, "WAVE", 4);
	memcpy(header.subChunk1ID, "fmt ", 4);
	memcpy(header.subchunk2ID, "data", 4);

	header.subchunk1Size = 16;
	header.audioFormat = 1;
	header.numChannels = 1; //1 or 2
	header.sampleRate = SAMPLE_RATE; //sample rate
	header.bitsPerSample = 32;
	header.blockAlign = header.numChannels
						* header.bitsPerSample / 8;
	header.byteRate = header.sampleRate
							* header.blockAlign;
	header.subchunk2Size = buf_size * 4;
	header.chunkSize = 36 + header.subchunk2Size;

	// Write WAV header
	res = f_write(&fil, &header, sizeof(WAVHeader), &br);
	if (res != FR_OK || br != sizeof(WAVHeader)) {
	    print("failed to write header\n");
	    f_close(&fil);
	    return;
	 }


	//write data
	res = f_write(&fil, (const void*)buf, buf_size * 4, &br) ;
	if(res != FR_OK){
		print("file write failed\n");
	    return ;
	}

	res = f_close(&fil);
	if (res) {
		return;
	}

	print("file successfully written\n");
}


int main()
{
    init_platform();

    print("Hello World\n");
    print("Audio Effects Processor Demo\n");
    print("========================================\n");

    // Initialize effect selector to Gain effect (default)
    // You can change this to test different effects before recording
    set_audio_effect(EFFECT_SPEED);  // Start with gain effect

    // Set gain from the AUDIO_GAIN configuration variable (defined at top of file)
    set_audio_gain(AUDIO_GAIN);

    set_speed_mode(SPEED_HALF);   /* SPEED_NORMAL / SPEED_X2 / SPEED_HALF */

    // Optional: Verify the settings were applied correctly
    uint8_t current_effect = get_audio_effect();
    uint32_t current_gain = get_audio_gain();
    uint32_t current_speed = get_speed_mode();
    xil_printf("Current effect: %s (ID=%d)\n", effect_names[current_effect], current_effect);
    xil_printf("Current gain: 0x%08X\n", current_gain);
    xil_printf("Current speed: 0x%08X (mode[1:0])\r\n", current_speed);
    print("========================================\n");

    //read from DMA
    dma();

	//mount sd
    FRESULT rc;
    rc = f_mount(&fatfs, "0:/", 1);
    xil_printf("f_mount rc=%d\r\n", rc);
    if (rc != FR_OK) {
    	print("failed to mount sd card\n");
        return 0 ;
    }
    else {
    	print("sd is mounted\n");
    }


    //write dma into file
    sd_write(rx_buf, BUF_SIZE, "0:/samples.wav");

    print("Successfully ran Hello World application");
    cleanup_platform();
    return 0;
}
