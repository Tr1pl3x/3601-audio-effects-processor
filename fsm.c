o.h>
#include "platform.h"
#include "xil_printf.h"
#include "xaxidma.h"
#include "sleep.h"
#include "ff.h"
#include "xsdps.h"
#include "xuartps.h"
#include <string.h>
#include "xparameters.h"
#include "xil_io.h"
#include "sleep.h"

//for the button
#define AXI_GPIO_SW_OFFSET  0x00000004
//#define XPAR_AXI_GPIO_0_BASEADDR A0030000

//STATE FOR FSM
#define NONE 0	//the starting state
#define ECHO 1	//echo audio effect
#define GAIN 2	//gain audio effect
#define SPEED 3	//speed audio effect
#define CLIPPING 4 //clipping audio effect
#define FLANGER 5  //flanger audio effect
#define WRITE_FILE 6 //like NONE but at the beginning the file is written

//file buffer
#define BUF_SIZE 28800000 //48000 * 600 (time limit is 10 minutes)
#define BATCH_SIZE 1024	  //we read 1024 samples at once
#define SAMPLES_READ_AT_ONCE 5 //we read 5 * 1024 before checking the button every time
volatile uint32_t rx_buf[BUF_SIZE] = {}; //declare a 10 minute buffer

//For axi dma
XAxiDma AxiDma; //DMA oject

//for sd
static FIL fil; //file object
static FATFS fatfs; //filesystem object
MKFS_PARM mkfs_parm; //parameters to make filesystem


//constants
#define SAMPLE_SIZE 32 //size of sample
#define SAMPLE_PMC 18  //number of valid bits per sample
#define EXTRA_BITS SAMPLE_SIZE - SAMPLE_PMC //the useless bits
#define SAMPLE_RATE 48000 //sample rate of the i2s microphone

//wav file header
//source: http://soundfile.sapp.org/doc/WaveFormat/
typedef struct {
    char chunkID[4];        // "RIFF"
    uint32_t chunkSize;     // 36 + data size
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
    uint32_t subchunk2Size; // bytes of PCM data
} WAVHeader;


//write into sd card function
int sd_write(volatile uint32_t *buf, int buf_size, char *name) {
 FRESULT res; //result of file operations
 //open the file
 res = f_open(&fil, name, FA_CREATE_ALWAYS | FA_WRITE);
 unsigned int br;
 if(res != FR_OK)
   {
  xil_printf("file creation failed, FRESULT=%d\n", res);
  print("file creation failed\n");
     return -1;
   }

 res = f_lseek(&fil, 0);
 if (res) {
  f_close(&fil);
  return -1;
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
     return - 1;
  }


 //write data
 res = f_write(&fil, (const void*)buf, buf_size * 4, &br) ;
 if(res != FR_OK){
  print("file write failed\n");
  	 f_close(&fil);
     return -1 ;
 }

 res = f_close(&fil);
 if (res) {
  return;
 }

 print("file successfully written\n");
}

//configure the dma
int dma_config() {
    //declare necessary variables
	int Status = XST_SUCCESS;
	XAxiDma_Config *CfgPtr;

	//no scatter-gather
	CfgPtr = XAxiDma_LookupConfig(XPAR_AXI_DMA_0_DEVICE_ID);
	if (!CfgPtr) {
		print("No CfgPtr");
	    return XST_FAIL;
	}

	//init configuration
	Status = XAxiDma_CfgInitialize(&AxiDma, CfgPtr);
	    if (Status != XST_SUCCESS) {
	        print("DMA cfg init failure");
	        return XST_FAILURE;
	   }

	   if (XAxiDma_HasSg(&AxiDma)) {
	       print("Device configured as SG mode \r\n");
	       return XST_FAILURE;
	   }

	   print("DMA initialised\r\n");

	   //self test to check if it is configured properly
	   Status = XAxiDma_Selftest(&AxiDma);
	   if (Status != XST_SUCCESS) {
	         print("DMA failed selftest\r\n");
	         return XST_FAILURE;
	    }
	    print("DMA passed self test\r\n");

	    //polling rather than interrupts
	    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK,
	    XAXIDMA_DEVICE_TO_DMA);
	    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK,
	    XAXIDMA_DMA_TO_DEVICE);

        return XST_SUCCESS;
}

//read from the dma
void dma_read() {
	//READ SAMPLES_READ_AT_ONCE * BUF_SIZE samples
	for (int i = 0; i < SAMPLES_READ_AT_ONCE; i++) {
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

int new_state(int current_state) {
    switch (current_state) {
        case 0:
        case 1:
        case 2:
        case 3:
        case 4:
        case 5:
            return current_state + 1;
        case 6:
            return 1;
        default:
            return 0; // optional: handle unexpected values
    }
}

//configure the sd card
int config_sd() {
    //mount sd
    FRESULT rc;
    rc = f_mount(&fatfs, "0:/", 1);
    if (rc != FR_OK) {
    	print("failed to mount sd card\n");
        return rc;
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
        return rc;
    	xil_printf("f_mkfs failed, FRESULT=%d\n", rc);
    }
    else {
    	xil_printf("successfully made the file system\n");
    }

    return rc;
}

int main() {

 int state = NONE;
 int buf_stored_size = 0;
 int file_written_count = 0;
 char filename[3] = "aud"; //4 chars for file index, 1 for '\0'
 char full_filename[8];

//button state
int button_state = 0;
int button_state_prev = 0;

 dma_config();
 config_sd();

 while(1) {
	 //get the new file name
    snprintf(full_filename, sizeof(full_filename), "%s%d", filename, file_written_count);
    //read the samples from dma
    dma_read();
    //updated the buffer size
    file_written_count += BUF_SIZE * SAMPLES_READ_AT_ONCE;
    //if the buffer is filled
    if (file_written_count == BUF_SIZE) {
    	//write the file, update file counter and reset the buffer size
        sd_write(rx_buf, buf_stored_size, full_filename);
        buf_stored_size = 0;
        file_written_count += 1;
    }
    //check the button
    button_state_prev = button_state;
    button_state = Xil_In32(XPAR_AXI_GPIO_0_BASEADDR //A0030000
		    	  	  	  	+ AXI_GPIO_SW_OFFSET);

    if (button_state != button_state_prev) {
        state = new_state(state);
    }
 }
