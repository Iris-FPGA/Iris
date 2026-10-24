// Diagnostic only: known DDR pattern -> hardware CI read/copy/read.
// Executes and records results in OCR; never uses CPU reads as pixel evidence.
#include <stdint.h>
#include "bsp.h"
#include "clint.h"
#include "riscv.h"
#ifndef IRIS_DMA_PROBE_SRC
#define IRIS_DMA_PROBE_SRC 0x00700000u
#endif
#ifndef IRIS_DMA_PROBE_DST
#define IRIS_DMA_PROBE_DST 0x03000000u
#endif
#ifndef IRIS_DMA_PROBE_CAPTURE
#define IRIS_DMA_PROBE_CAPTURE 0
#endif
static uint32_t pattern(uint32_t i) {
    return 0x80000000u | ((i*0x010203u ^ 0x005a173cu)&0x00ffffffu);
}
static uint32_t state(void) {return opcode_R(CUSTOM0,5,64,0,0);}
static void config(uint32_t src,uint32_t dst) {
    opcode_R(CUSTOM0,1,64,src,dst);
    opcode_R(CUSTOM0,2,64,16,1024);
    opcode_R(CUSTOM0,3,64,4,0);
}
static uint32_t stream(uint32_t src,volatile uint32_t *result,int compare) {
    config(src,0);
    if(opcode_R(CUSTOM0,7,65,0,0)!=0)return 0xffffffffu;
    uint32_t errors=0;
    for(uint32_t i=0;i<16384;i+=4) {
        const uint64_t begin=clint_getTime(BSP_CLINT);
        while(!(state()&8u)) {
            if(!(state()&1u) || clint_getTime(BSP_CLINT)-begin>SYSTEM_CLINT_HZ)
                return 0xfffffffeu;
        }
        const uint32_t v[4]={opcode_R(CUSTOM0,2,65,0,0),opcode_R(CUSTOM0,3,65,0,0),
                            opcode_R(CUSTOM0,4,65,0,0),opcode_R(CUSTOM0,5,65,0,0)};
        for(unsigned k=0;k<4;++k) {
            if(compare && v[k]!=pattern(i+k)) {
                if(errors++==0) {result[0]=src+4*(i+k);result[1]=v[k];result[2]=pattern(i+k);}
            }
        }
        opcode_R(CUSTOM0,6,65,0,0);
    }
    result[3]=opcode_R(CUSTOM0,1,65,0,0);
    return compare ? errors : result[3];
}
void probe_main(void) {
    volatile uint32_t *s=(volatile uint32_t *)0xf9000e00;
    volatile uint32_t *src=(volatile uint32_t *)IRIS_DMA_PROBE_SRC;
    for(unsigned i=0;i<32;++i)s[i]=0;
    s[0]=1;bsp_init();
    s[23]=opcode_R(CUSTOM0,0,64,0,0);
#if IRIS_DMA_PROBE_CAPTURE
    volatile uint32_t *demo=(volatile uint32_t *)0xf8100000;
    uint64_t first_complete=0,span=0;
    for(unsigned n=0;n<IRIS_DMA_PROBE_CAPTURE;++n) {
        demo[1]=0;demo[0]=1;
        const uint64_t capture_begin=clint_getTime(BSP_CLINT);
        while(!(demo[0]&1u))if(clint_getTime(BSP_CLINT)-capture_begin>2u*SYSTEM_CLINT_HZ){s[0]=0xbad00004;return;}
        while(demo[0]&1u)if(clint_getTime(BSP_CLINT)-capture_begin>2u*SYSTEM_CLINT_HZ){s[0]=0xbad00005;return;}
        if((demo[0]&7u)!=2u || demo[10] || demo[11]){s[0]=0xbad00006;return;}
        const uint64_t completed=clint_getTime(BSP_CLINT);
        if(n==0)first_complete=completed;
        span=completed-first_complete;
    }
    s[17]=(uint32_t)span;s[8]=(uint32_t)(span>>32);
    s[18]=demo[0];s[19]=demo[10];s[20]=demo[11];s[21]=demo[5];
#endif
    // Check CPU stores before any CI DMA operation, on a fresh SRAM load.
    s[0]=3;
    for(unsigned i=0;i<16384;++i)src[i]=pattern(i);
    __asm__ volatile(".word 0x0000500f; fence rw,rw" ::: "memory");
    // CPU read is only a diagnostic cross-check against the CI read below.
    // Full-array traversal exceeds the 1KiB cache; cache was flushed first.
    s[0]=0x10;
    for(unsigned i=0;i<16384;++i) {
        const uint32_t actual=src[i];
        if(actual!=pattern(i) && s[24]++==0) {
            s[25]=(uint32_t)&src[i];s[26]=actual;s[27]=pattern(i);
        }
    }
    s[0]=4;s[1]=stream(IRIS_DMA_PROBE_SRC,s+2,1);
#if IRIS_DMA_PROBE_CAPTURE
    s[22]=stream(IRIS_DMA_PROBE_DST,s+28,0);
#endif
    config(IRIS_DMA_PROBE_SRC,IRIS_DMA_PROBE_DST);s[0]=5;
    if(opcode_R(CUSTOM0,0,65,0,0)!=0){s[0]=0xbad00002;return;}
    const uint64_t begin=clint_getTime(BSP_CLINT);
    while(state()&1u)if(clint_getTime(BSP_CLINT)-begin>2u*SYSTEM_CLINT_HZ){s[0]=0xbad00003;return;}
    s[14]=state();s[15]=opcode_R(CUSTOM0,1,65,0,0);
    s[0]=6;s[9]=stream(IRIS_DMA_PROBE_DST,s+10,1);
    const uint64_t hold=clint_getTime(BSP_CLINT);
    while(clint_getTime(BSP_CLINT)-hold<SYSTEM_CLINT_HZ){}
    s[0]=7;s[16]=stream(IRIS_DMA_PROBE_DST,s+10,1);
    s[0]=(s[1] || s[9] || s[16] || s[5] || s[13] || s[14]!=2 || s[15]) ? 0xbad00001 : 0x600d0001;
    for(;;){}
}
