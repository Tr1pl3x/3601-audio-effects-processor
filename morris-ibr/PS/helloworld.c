///******************************************************************************
//* Copyright (C) 2023 Advanced Micro Devices, Inc. All Rights Reserved.
//* SPDX-License-Identifier: MIT
//******************************************************************************/
///*
// * helloworld.c: Audio capture application using DMA
// *
// * This application configures UART 16550 to baud rate 9600.
// * PS7 UART (Zynq) is not initialized by this application, since
// * bootrom/bsp configures it to baud rate 115200
// *
// * ------------------------------------------------
// * | UART TYPE   BAUD RATE                        |
// * ------------------------------------------------
// *   uartns550   9600
// *   uartlite    Configurable only in HW design
// *   ps7_uart    115200 (configured by bootrom/bsp)
// */
//#include <stdio.h>
//#include "platform.h"
//#include "xil_printf.h"
//#include "xaxidma.h"
//#include "xparameters.h"
//#include "sleep.h"
//#include "xil_cache.h"
//
//// Define the DMA device ID (adjust based on your xparameters.h)
//#define DMA_DEV_ID          XPAR_AXIDMA_0_DEVICE_ID
//
//// Audio configuration
//#define AUDIO_SAMPLES       1024        // Number of samples to capture
//#define BYTES_PER_SAMPLE    4           // Assuming 32-bit audio samples (adjust if needed)
//#define BUFFER_SIZE         (AUDIO_SAMPLES * BYTES_PER_SAMPLE)
//
//// Timeout for DMA operations (in microseconds)
//#define DMA_TIMEOUT_US      10000000    // 10 seconds
//
//// Audio buffer - align to cache line for better DMA performance
//u32 audio_buffer[AUDIO_SAMPLES] __attribute__((aligned(64)));
//
//// DMA instance
//XAxiDma AxiDma;
//
//int init_dma() {
//    XAxiDma_Config *CfgPtr;
//    int Status;
//
//    // Initialize the DMA driver
//    CfgPtr = XAxiDma_LookupConfig(DMA_DEV_ID);
//    if (!CfgPtr) {
//        xil_printf("Error: No config found for DMA %d\r\n", DMA_DEV_ID);
//        return XST_FAILURE;
//    }
//
//    Status = XAxiDma_CfgInitialize(&AxiDma, CfgPtr);
//    if (Status != XST_SUCCESS) {
//        xil_printf("Error: DMA initialization failed\r\n");
//        return XST_FAILURE;
//    }
//
//    // Check for scatter gather mode (we want simple DMA mode)
//    if(XAxiDma_HasSg(&AxiDma)) {
//        xil_printf("Error: Device configured as SG mode\r\n");
//        return XST_FAILURE;
//    }
//
//    // Disable interrupts for polling mode
//    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
//    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
//
//    return XST_SUCCESS;
//}
//
//int capture_audio() {
//    int Status;
//    u32 *BufferPtr;
//    int TimeoutCounter = 0;
//
//    BufferPtr = (u32 *)audio_buffer;
//
//    // Clear the buffer first
//    for(int i = 0; i < AUDIO_SAMPLES; i++) {
//        audio_buffer[i] = 0;
//    }
//
//    // Flush the cache to ensure buffer is in main memory
//    Xil_DCacheFlushRange((UINTPTR)audio_buffer, BUFFER_SIZE);
//
//    xil_printf("Starting audio capture of %d samples...\r\n", AUDIO_SAMPLES);
//
//    // Start the DMA transfer from audio pipeline to processor memory
//    // Using XAXIDMA_DEVICE_TO_DMA for receiving data
//    Status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)BufferPtr,
//                                    BUFFER_SIZE, XAXIDMA_DEVICE_TO_DMA);
//
//    if (Status != XST_SUCCESS) {
//        xil_printf("Error: Failed to start DMA transfer\r\n");
//        return XST_FAILURE;
//    }
//
//    // Wait for the transfer to complete
//    while ((XAxiDma_Busy(&AxiDma, XAXIDMA_DEVICE_TO_DMA)) &&
//           (TimeoutCounter < DMA_TIMEOUT_US)) {
//        usleep(1);
//        TimeoutCounter++;
//    }
//
//    if (TimeoutCounter >= DMA_TIMEOUT_US) {
//        xil_printf("Error: DMA transfer timeout\r\n");
//        return XST_FAILURE;
//    }
//
//    // Invalidate the cache to get fresh data from memory
//    Xil_DCacheInvalidateRange((UINTPTR)audio_buffer, BUFFER_SIZE);
//
//    xil_printf("Audio capture complete!\r\n");
//    xil_printf("Captured %d samples (%d bytes)\r\n", AUDIO_SAMPLES, BUFFER_SIZE);
//
//    return XST_SUCCESS;
//}
//
//void print_audio_stats() {
//    u32 min_val = 0xFFFFFFFF;
//    u32 max_val = 0;
//    u64 sum = 0;
//
//    // Calculate basic statistics
//    for(int i = 0; i < AUDIO_SAMPLES; i++) {
//        if(audio_buffer[i] < min_val) min_val = audio_buffer[i];
//        if(audio_buffer[i] > max_val) max_val = audio_buffer[i];
//        sum += audio_buffer[i];
//    }
//
//    xil_printf("\r\n--- Audio Buffer Statistics ---\r\n");
//    xil_printf("Min value: 0x%08X\r\n", min_val);
//    xil_printf("Max value: 0x%08X\r\n", max_val);
//    xil_printf("Average: 0x%08X\r\n", (u32)(sum / AUDIO_SAMPLES));
//
//    // Print first 10 samples as a preview
//    xil_printf("\r\nFirst 10 samples:\r\n");
//    for(int i = 0; i < 10 && i < AUDIO_SAMPLES; i++) {
//        xil_printf("  [%d]: 0x%08X\r\n", i, audio_buffer[i]);
//    }
//}
//
//int main()
//{
//    int Status;
//
//    init_platform();
//
//    print("Audio Capture Application Starting\n\r");
//    print("==================================\n\r");
//
//    // Initialize DMA
//    Status = init_dma();
//    if (Status != XST_SUCCESS) {
//        xil_printf("DMA initialization failed\r\n");
//        cleanup_platform();
//        return XST_FAILURE;
//    }
//    xil_printf("DMA initialized successfully\r\n");
//
//    // Capture audio samples
//    Status = capture_audio();
//    if (Status != XST_SUCCESS) {
//        xil_printf("Audio capture failed\r\n");
//        cleanup_platform();
//        return XST_FAILURE;
//    }
//
//    // Print statistics about captured audio
//    print_audio_stats();
//
//    // *** BREAKPOINT HERE ***
//    // Set a breakpoint on the next line to examine audio_buffer contents
//    // In debugger, examine: audio_buffer[0] through audio_buffer[1023]
//    xil_printf("\r\n*** Set breakpoint here to examine audio_buffer ***\r\n");
//
//    // This NOP ensures the breakpoint line isn't optimized away
//    asm("nop");
//
//    // You can also examine specific samples here
//    // For example, to see sample at index 512:
//    u32 middle_sample = audio_buffer[1091];
//    xil_printf("Sample at index 512: 0x%08X\r\n", middle_sample);
//
//    print("\r\nAudio capture demonstration complete!\r\n");
//    cleanup_platform();
//
//    return 0;
//}
//
//


// test_uart_echo.c
#include <stdio.h>
#include <string.h>
#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xaxidma.h"
#include "xparameters.h"
#include "sleep.h"
#include "xil_cache.h"

// Simple UART echo program for Kria KV260
void main() {
    uart_init(115200);  // Initialize UART

    uart_print("=== UART Echo Test ===\r\n");
    uart_print("Type anything and press Enter.\r\n");
    uart_print("System will echo back what you type.\r\n");
    uart_print("Type 'exit' to quit.\r\n");
    uart_print("========================\r\n");

    char buffer[100];

    while(1) {
        uart_print("Test> ");

        // Read user input
        int i = 0;
        while(1) {
            if(uart_data_available()) {
                char c = uart_read();
                uart_send_char(c);  // Echo character back

                if(c == '\r') {  // Enter key
                    buffer[i] = '\0';
                    uart_print("\r\n");
                    break;
                } else {
                    buffer[i++] = c;
                }
            }
        }

        // Process command
        if(strcmp(buffer, "exit") == 0) {
            uart_print("Goodbye!\r\n");
            break;
        } else {
            uart_print("You typed: ");
            uart_print(buffer);
            uart_print("\r\n");
        }
    }
}
