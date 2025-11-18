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
#include "xparameters.h"
#include "xil_io.h"
#include "xiicps.h"
//#include "xgpio.h"

#define BUF_SIZE 1440768 //48000 * 30
#define BATCH_SIZE 1024

//save the state information
uint8_t state_select;

// Double buffering: Buffer A and Buffer B for continuous recording
volatile uint32_t rx_buf_A[BUF_SIZE] = {};
volatile uint32_t rx_buf_B[BUF_SIZE] = {};

//for sd
static FIL fil;
static FATFS fatfs;
MKFS_PARM mkfs_parm;

//constants
#define SAMPLE_SIZE 32
#define SAMPLE_PMC 18
#define EXTRA_BITS SAMPLE_SIZE - SAMPLE_PMC
#define SAMPLE_RATE 48000

//for gpio
//for the button
#define AXI_GPIO_SW_OFFSET  0x00000004
#define AXI_GPIO_LED_OFFSET  0x00000000
//#define XPAR_AXI_GPIO_0_BASEADDR A0030000
//for interacting with the audio PL
#define AXI_AUDIO_SEL_OFFSET 0x00000000

//Audio pipeline control registers
//Base address from xparameters.h: XPAR_AUDIO_PIPELINE_0_BASEADDR
#define AUDIO_PIPELINE_BASEADDR XPAR_AUDIO_PIPELINE_0_BASEADDR  // 0xA0000000
#define CONTROL_REG_OFFSET 0x00  // slv_reg0 at offset 0x00 (effect selector in bits [2:0])
#define GAIN_REG_OFFSET 0x0C  // slv_reg3 at offset 0x0C
#define SPEED_REG_OFFSET 0x1C  /* slv_reg7£ºspeed_mode Bits[1:0] */

// Echo effect control registers
#define ECHO_DELAY_OFFSET 0x10     // slv_reg4: delay time in samples (0 to 12000)
#define ECHO_FEEDBACK_OFFSET 0x14  // slv_reg5: feedback gain (Q16.16 format, 0.0 to 0.9)
#define ECHO_MIX_OFFSET 0x18       // slv_reg6: wet/dry mix (Q16.16 format, 0.0 to 1.0)

// AXI GPIO IP - Using Xilinx GPIO driver
//XGpio Gpio; // GPIO instance
#define GPIO_DEVICE_ID XPAR_GPIO_0_DEVICE_ID
#define LED_CHANNEL 1    // Channel 1 for LED (output)
#define BUTTON_CHANNEL 2 // Channel 2 for Button (input)

//Gain values in Q16.16 fixed-point format
//Format: 16 integer bits + 16 fractional bits
#define GAIN_MUTE    0x00000000  // 0.0x - Mute
#define GAIN_HALF    0x00008000  // 0.5x - Half volume
#define GAIN_UNITY   0x00010000  // 1.0x - No change (default)
#define GAIN_1_5X    0x00018000  // 1.5x - 50% boost
#define GAIN_2X      0x00020000  // 2.0x - Double volume
#define GAIN_4X      0x00040000  // 4.0x - Quadruple volume
#define GAIN_8X      0x00080000  // 8.0x - 8x boost (may clip/saturate)

// Echo effect parameter values in Q16.16 fixed-point format
// Delay time: In samples (not Q16.16, just integer sample count)
#define ECHO_DELAY_50MS    2400    // 50ms at 48kHz = 2400 samples
#define ECHO_DELAY_100MS   4800    // 100ms at 48kHz = 4800 samples
#define ECHO_DELAY_125MS   6000    // 125ms at 48kHz = 6000 samples
#define ECHO_DELAY_150MS   7200    // 150ms at 48kHz = 7200 samples
#define ECHO_DELAY_200MS   9600    // 200ms at 48kHz = 9600 samples
#define ECHO_DELAY_250MS   12000   // 250ms at 48kHz = 12000 samples (maximum)
// Feedback gain: Q16.16 format (controls echo repetition strength)
#define ECHO_FEEDBACK_NONE  0x00000000  // 0.0 - No feedback (single echo only)
#define ECHO_FEEDBACK_LIGHT 0x00004000  // 0.25 - Light feedback (echo fades quickly)
#define ECHO_FEEDBACK_MED   0x00008000  // 0.5 - Medium feedback (balanced repetition)
#define ECHO_FEEDBACK_HEAVY 0x0000C000  // 0.75 - Heavy feedback (long decay)
#define ECHO_FEEDBACK_MAX   0x0000E666  // 0.9 - Maximum feedback (near infinite)
// Wet/dry mix: Q16.16 format (0.0 = all original, 1.0 = all echo)
#define ECHO_MIX_DRY        0x00000000  // 0.0 - Only original signal (no echo heard)
#define ECHO_MIX_LIGHT      0x00004000  // 0.25 - Mostly original + subtle echo
#define ECHO_MIX_BALANCED   0x00008000  // 0.5 - Equal mix of original and echo
#define ECHO_MIX_HEAVY      0x0000C000  // 0.75 - Mostly echo + subtle original
#define ECHO_MIX_WET        0x00010000  // 1.0 - Only echo signal (no original)

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

//Effect names for display (matches the order above)
const char *effect_names[] = {
    "None (Bypass)",
    "Echo",
    "Gain",
    "Speed",
    "Clipping",
    "Flanger"
};

//function prototypes
void sd_write(volatile uint32_t *buf, int buf_size, int file_number);


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

static inline void set_led(int on)
{
    Xil_Out32(XPAR_AXI_GPIO_0_BASEADDR + AXI_GPIO_LED_OFFSET,
              on ? 0x1 : 0x0);
}

void blink_led_for_effect(uint8_t effect_id)
{
    const int on_ms  = 200;
    const int off_ms = 200;

    int count = effect_id;

    for (int i = 0; i < count; ++i) {
        set_led(1);
        usleep(on_ms * 1000);
        set_led(0);
        usleep(off_ms * 1000);
    }
}
/**
 * Initialize AXI GPIO for LED and Button
 */
/*int init_gpio(void) {
    int Status;

    // Initialize GPIO driver
    Status = XGpio_Initialize(&Gpio, GPIO_DEVICE_ID);
    if (Status != XST_SUCCESS) {
        xil_printf("GPIO Initialization failed\r\n");
        return XST_FAILURE;
    }

    // Set LED channel as output
    XGpio_SetDataDirection(&Gpio, LED_CHANNEL, 0x00);

    // Set Button channel as input
    XGpio_SetDataDirection(&Gpio, BUTTON_CHANNEL, 0xFF);

    // Initialize LED to off
    XGpio_DiscreteWrite(&Gpio, LED_CHANNEL, 0x00);

    xil_printf("GPIO Initialized successfully\r\n");
    return XST_SUCCESS;
}*/

/**
 * Update LED pattern based on current effect
 */

/**
 * Check for button press with debouncing
 */
/*int check_button_press(void) {
    static u32 last_stable_state = 1;  // Button not pressed initially (pull-up)
    static u32 debounce_counter = 0;
    u32 current_button_state;

    // Read button state
    current_button_state = XGpio_DiscreteRead(&Gpio, BUTTON_CHANNEL) & 0x01;

    // Debouncing logic
    if (current_button_state == last_stable_state) {
        // Button state is stable, reset counter
        debounce_counter = 0;
    } else {
        // Button state is different from last stable state
        debounce_counter++;
        if (debounce_counter > 1000) {
            // State has been different long enough, accept the change
            if (current_button_state == 0) {
                // Button press detected (falling edge: 1 -> 0)
                last_stable_state = current_button_state;
                debounce_counter = 0;
                return 1;
            }
            // Button released (rising edge: 0 -> 1)
            last_stable_state = current_button_state;
            debounce_counter = 0;
        }
    }

    return 0;
}

/**
 * Set the audio gain via memory-mapped register write
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
 */
uint32_t get_audio_gain(void) {
    return Xil_In32(AUDIO_PIPELINE_BASEADDR + GAIN_REG_OFFSET);
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

/**
 * Set the active audio effect via memory-mapped register write
 */
void set_audio_effect(uint8_t effect_id) {
    // Ensure effect_id is in valid range (0-5)
    if (effect_id > 5) {
        xil_printf("Invalid effect ID: %d. Must be 0-5.\r\n", effect_id);
        return;
    }

    //write the state
    state_select = effect_id;

    // Read current control register value
    uint32_t control_reg = Xil_In32(AUDIO_PIPELINE_BASEADDR + CONTROL_REG_OFFSET);

    // Clear bits [2:0] and set new effect selector
    control_reg = (control_reg & 0xFFFFFFF8) | (effect_id & 0x07);

    // Write back to control register
    Xil_Out32(AUDIO_PIPELINE_BASEADDR + CONTROL_REG_OFFSET, control_reg);

    xil_printf("Effect changed to: %s (ID=%d)\r\n", effect_names[effect_id], effect_id);

    blink_led_for_effect(effect_id);
}

/**
 * Read current effect selection from hardware register
 */
uint8_t get_audio_effect(void) {
    //uint32_t control_reg = Xil_In32(AUDIO_PIPELINE_BASEADDR + CONTROL_REG_OFFSET);
    //return (uint8_t)(control_reg & 0x07);  // Extract bits [2:0]
	return state_select;
}

/**
 * Cycle to the next effect in the sequence
 */
void cycle_to_next_effect(void) {
    uint8_t current = get_audio_effect();
    uint8_t next_effect = (current + 1) % 6;  // Cycle 0->1->2->3->4->5->0
    set_audio_effect(next_effect);
}

// I2C configuration for audio codec (assuming ADAU1761 or similar)
#define I2C_DEVICE_ID XPAR_XIICPS_0_DEVICE_ID
#define CODEC_I2C_ADDR 0x38  // ADAU1761 default address

/**
 * Initialize speaker codec via I2C
 */
int init_speaker_codec(void) {
    XIicPs Iic;
    XIicPs_Config *IicConfig;
    int Status;

    xil_printf("Initializing speaker codec...\r\n");

    // Initialize I2C
    IicConfig = XIicPs_LookupConfig(I2C_DEVICE_ID);
    if (IicConfig == NULL) {
        xil_printf("I2C config not found\r\n");
        return XST_FAILURE;
    }

    Status = XIicPs_CfgInitialize(&Iic, IicConfig, IicConfig->BaseAddress);
    if (Status != XST_SUCCESS) {
        xil_printf("I2C init failed\r\n");
        return XST_FAILURE;
    }

    // Set I2C frequency
    XIicPs_SetSClk(&Iic, 100000); // 100 kHz

    // Basic codec configuration for ADAU1761
    // Note: This is a simplified configuration - adjust for your specific codec
    uint8_t codec_config[][2] = {
        {0x40, 0x01}, // Enable master clock
        {0x41, 0x01}, // Enable PLL
        {0x42, 0x01}, // Enable DAC
        {0x43, 0x01}, // Enable output
        {0x44, 0x03}, // Set volume
        {0x45, 0x00}, // Unmute
    };

    for (int i = 0; i < sizeof(codec_config)/sizeof(codec_config[0]); i++) {
        uint8_t data[2] = {codec_config[i][0], codec_config[i][1]};
        Status = XIicPs_MasterSendPolled(&Iic, data, 2, CODEC_I2C_ADDR);
        if (Status != XST_SUCCESS) {
            xil_printf("Codec config failed at register 0x%02x\r\n", codec_config[i][0]);
            return XST_FAILURE;
        }
        usleep(1000); // Small delay between writes
    }

    xil_printf("Speaker codec initialized successfully\r\n");
    return XST_SUCCESS;
}

void dma_continuous() {
	//declare necessary variables
	int Status = XST_SUCCESS;
	XAxiDma_Config *CfgPtr;
	XAxiDma AxiDma;
	uint32_t button_state, button_state_prev = 0;

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

	    // Double buffering variables
	    volatile uint32_t *active_buffer;
	    volatile uint32_t *write_buffer;
	    int file_counter = 1;
	    int use_buffer_A = 1;  // Start with Buffer A

	    print("Starting continuous recording with double buffering...\r\n");
	    print("Press button to cycle audio effects\r\n");
	    print("Recording will run indefinitely, creating new files every 30 seconds\r\n\n");

	    //INFINITE LOOP for continuous recording
	    while (1) {
	        // Select active buffer (for DMA recording)
	        if (use_buffer_A) {
	            active_buffer = rx_buf_A;
	            write_buffer = rx_buf_B;
	            xil_printf("Recording to Buffer A (File #%d will be AUD%03d.wav)...\r\n",
	                       file_counter, file_counter);
	        } else {
	            active_buffer = rx_buf_B;
	            write_buffer = rx_buf_A;
	            xil_printf("Recording to Buffer B (File #%d will be AUD%03d.wav)...\r\n",
	                       file_counter, file_counter);
	        }

	        // Fill the active buffer with DMA transfers (30 seconds of audio)
	        for (int i = 0; i < BUF_SIZE / BATCH_SIZE; i++) {
	            Xil_DCacheFlushRange((UINTPTR)(active_buffer + i * BATCH_SIZE), BATCH_SIZE * 4);

	            // Check for button press and update LED while waiting
	            button_state_prev = button_state;
	            button_state = Xil_In32(XPAR_AXI_GPIO_0_BASEADDR //A0030000
	            		    	  	  	+ AXI_GPIO_SW_OFFSET);
	            if ((button_state == 0) && (button_state_prev == 1)) {
	            	cycle_to_next_effect();
	            }

	            //read from DMA
	            Status = XAxiDma_SimpleTransfer(&AxiDma, (UINTPTR)(active_buffer + i * BATCH_SIZE),
	                BATCH_SIZE * 4, XAXIDMA_DEVICE_TO_DMA);

	            if (Status != XST_SUCCESS) {
	                print("failed rx transfer call\r\n");
	            }

	            while (XAxiDma_Busy(&AxiDma, XAXIDMA_DEVICE_TO_DMA)) {
	                // Check for button press and update LED while waiting
	            	button_state_prev = button_state;
	            	button_state = Xil_In32(XPAR_AXI_GPIO_0_BASEADDR //A0030000
		    	  	  	  			+ AXI_GPIO_SW_OFFSET);
	                if ((button_state == 0) && (button_state_prev == 1)) {
	                    cycle_to_next_effect();
	                }
	            }

	            //flush
	            Xil_DCacheFlushRange((UINTPTR)(active_buffer + i * BATCH_SIZE), BATCH_SIZE * 4);
	        }

	        // Buffer is full (30 seconds recorded)
	        xil_printf("Buffer full! Writing to SD card...\r\n");

	        // Write the active buffer to SD card with auto-incremented filename
	        sd_write(active_buffer, BUF_SIZE, file_counter);

	        xil_printf("File AUD%03d.wav written successfully\r\n\n", file_counter);

	        // Increment file counter and swap buffers
	        file_counter++;
	        use_buffer_A = !use_buffer_A;  // Toggle between buffers

	        // Continue infinite loop - never exits
	    }
}

void sd_write(volatile uint32_t *buf, int buf_size, int file_number) {
	FRESULT res;
	char filename[32];
	unsigned int br;

	// Generate filename with auto-increment number: audio_001.wav, audio_002.wav, etc.
	// Use format that matches working reference code
	sprintf(filename, "0:/AUD%03d.WAV", file_number);

	xil_printf("Attempting to open file: %s\n", filename);
	res = f_open(&fil, filename, FA_CREATE_ALWAYS | FA_WRITE);
	xil_printf("f_open returned: %d\n", res);

	if(res != FR_OK)
	  {
		xil_printf("ERROR: File creation failed, FRESULT=%d\n", res);
		print("Possible causes: SD card write-protected, corrupted, or full\n");
		f_close(&fil);  // Ensure fil is closed on error
	    return ;
	  }
	print("File opened successfully\n");

	res = f_lseek(&fil, 0);
	if (res) {
		print("ERROR: f_lseek failed\n");
		f_close(&fil);
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
	    print("ERROR: Failed to write WAV header\n");
	    f_close(&fil);
	    return;
	 }

	//write data
	res = f_write(&fil, (const void*)buf, buf_size * 4, &br) ;
	if(res != FR_OK){
		print("ERROR: File write failed\n");
		f_close(&fil);
	    return ;
	}

	res = f_close(&fil);
	if (res) {
		print("ERROR: f_close failed\n");
		return;
	}

	print("File successfully written\n");
}

int main()
{
    init_platform();

    print("Hello World\n");
    print("Audio Effects Processor with Speaker Output\n");
    print("========================================\n");
    print("Button Control: PMOD BTN to cycle effects\n");
    print("LED Status: Different blink patterns for each effect\n");
    print("========================================\n");

    // Initialize GPIO for LED and Button
    /*if (init_gpio() != XST_SUCCESS) {
        print("Warning: GPIO initialization failed\n");
        print("Button and LED functionality may not work\n");
    }*/

    // Initialize speaker codec
    if (init_speaker_codec() != XST_SUCCESS) {
        print("Warning: Speaker codec initialization failed\n");
        print("Audio will be processed but may not output to speaker\n");
    }

    // Initialize effect selector to None/Bypass effect (default)
    set_audio_effect(EFFECT_NONE);
    set_audio_gain(AUDIO_GAIN);
    set_speed_mode(SPEED_X2);   /* SPEED_NORMAL / SPEED_X2 / SPEED_HALF */

    // Initialize echo effect parameters
    Xil_Out32(AUDIO_PIPELINE_BASEADDR + ECHO_DELAY_OFFSET, ECHO_DELAY_100MS);      // 100ms delay
    Xil_Out32(AUDIO_PIPELINE_BASEADDR + ECHO_FEEDBACK_OFFSET, ECHO_FEEDBACK_MED);  // 0.5 feedback
    Xil_Out32(AUDIO_PIPELINE_BASEADDR + ECHO_MIX_OFFSET, ECHO_MIX_BALANCED);       // 0.5 wet/dry mix

    // Optional: Verify the settings were applied correctly
    uint8_t current_effect = get_audio_effect();
    uint32_t current_gain = get_audio_gain();
    xil_printf("Current effect: %s (ID=%d)\n", effect_names[current_effect], current_effect);
    xil_printf("Current gain: 0x%08X\n", current_gain);

    // Print LED pattern guide
    print("\nLED Pattern Guide:\n");
    print("Effect 0 (None): Slow blink (1Hz)\n");
    print("Effect 1 (Echo): Fast blink (4Hz)\n");
    print("Effect 2 (Gain): Double blink pattern\n");
    print("Effect 3 (Speed): Triple blink pattern\n");
    print("Effect 4 (Clipping): Rapid blink (8Hz)\n");
    print("Effect 5 (Flanger): Alternating long/short\n");
    print("========================================\n\n");

    // Mount SD card (using drive 1:/ like working reference code)
    FRESULT rc;
    print("Mounting SD card at 0:/...\n");
    rc = f_mount(&fatfs, "0:/", 1);
    if (rc != FR_OK) {
        xil_printf("ERROR: Failed to mount SD card, FRESULT=%d\n", rc);
        print("Please insert SD card and reset the system\n");
        return 0;
    }
    print("SD card mounted successfully\n\n");

    // Check if FatFs is in read-only mode (diagnostic)
    #ifdef FF_FS_READONLY
        #if FF_FS_READONLY == 1
            print("WARNING: FatFs is compiled in READ-ONLY mode!\n");
            print("File writes will fail. Rebuild BSP with write support enabled.\n\n");
        #else
            print("FatFs read/write mode: ENABLED\n");
        #endif
    #endif

    // Start continuous DMA recording with double buffering
    // This function runs forever - creates audio_001.wav, audio_002.wav, etc.
    dma_continuous();

    // Never reaches here (infinite loop)
    cleanup_platform();
    return 0;
}
