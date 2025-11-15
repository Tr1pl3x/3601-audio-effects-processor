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
#include "platform.h"
#include "xil_printf.h"
#include "xaxidma.h"
#include "sleep.h"
#include "ff.h"
#include "xsdps.h"

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
	res = f_open(&fil, name, FA_CREATE_ALWAYS | FA_WRITE);
	unsigned int br;
	if(res != FR_OK)
	  {
		xil_printf("file creation failed, FRESULT=%d\n", res);
		print("file creation failed\n");
	    return ;
	  }

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

    //read from DMA
    dma();

	//mount sd
    FRESULT rc;
    rc = f_mount(&fatfs, "0:/", 1);
    if (rc != FR_OK) {
    	print("failed to mount sd card\n");
        return 0 ;
    }
    else {
    	print("sd is mounted\n");
    }

    //IMPORTANT: make file system: only needs to be done ONCE. Don't do this on every boot.
    //uncomment if you use the sd card for the first time
    //it can take a lot of time (minutes)

    //mkfs_parm.fmt = FM_FAT32;
    //BYTE work[FF_MAX_SS];
    //rc = f_mkfs("0:/", &mkfs_parm , work, sizeof work);

    if (rc != FR_OK) {
    	xil_printf("f_mkfs failed, FRESULT=%d\n", rc);
    }
    else {
    	xil_printf("successfully made the file system\n");
    }

    //write dma into file
    sd_write(rx_buf, BUF_SIZE, "samples.wav");

    print("Successfully ran Hello World application");
    cleanup_platform();
    return 0;
}