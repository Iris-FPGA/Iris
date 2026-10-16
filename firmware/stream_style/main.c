// CPU loads parameters, controls ownership and handles IRQ. All pixels travel
// through hardware DMA/Conv/NN2x; there are no CPU pixel loads or image math.
#include <stdint.h>
#include "bsp.h"
#include "clint.h"
#include "plic.h"
#include "riscv.h"
#include "stream_model.h"
#ifndef IRIS_STREAM_SNAPSHOT
#define IRIS_STREAM_SNAPSHOT 0
#endif
volatile uint32_t iris_stream_control[16];
static volatile uint32_t irq_seen,irq_status;
static uint32_t cnn_status(void){return opcode_R(CUSTOM0,6,72,0,0);}
static void flush(void){__asm__ volatile(".word 0x0000500f; fence rw,rw" ::: "memory");}
static void stop(const char *why){
    csr_write(mie,0);iris_stream_control[0]=0xbad00001;
    bsp_printf("IRIS STOP: %s\n",why);for(;;){}
}
void trap(void){
    const uint32_t cause=csr_read(mcause);
    if(cause==0x8000000bu){
        uint32_t id;
        while((id=plic_claim(BSP_PLIC,BSP_PLIC_CPU_0))!=0){
            if(id!=SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT)stop("unexpected external IRQ");
            const uint32_t status=cnn_status();
            if((status&7u)!=2u)stop("CNN IRQ without completed frame");
            irq_status=status;irq_seen=1;
            if(opcode_R(CUSTOM0,4,73,0,0)!=0)stop("CNN completion ACK failed");
            plic_release(BSP_PLIC,BSP_PLIC_CPU_0,id);
        }
    }else{
        iris_stream_control[12]=cause;iris_stream_control[13]=csr_read(mepc);iris_stream_control[14]=csr_read(mtval);
        stop("CPU trap");
    }
}
static uint32_t rz_status(void){return opcode_R(CUSTOM0,5,64,0,0);}
static void export_frame(uint32_t src,const char *kind){
    flush();
    if(opcode_R(CUSTOM0,0,64,0,0)!=0x49520101u || opcode_R(CUSTOM0,1,64,src,0)!=0 ||
       opcode_R(CUSTOM0,2,64,480,640)!=0 || opcode_R(CUSTOM0,3,64,4,0)!=0 ||
       opcode_R(CUSTOM0,7,65,0,0)!=0)stop("hardware export config");
    bsp_printf("IRIS STREAM %s bytes=1228800 baud=500000\n",kind);
    bsp_uDelay(20000);
    write_u32(SYSTEM_CLINT_HZ/(500000u*BSP_UART_DATA_LEN)-1,BSP_UART_TERMINAL+UART_CLOCK_DIVIDER);
    uint64_t deadline=clint_getTime(BSP_CLINT)+5ull*SYSTEM_CLINT_HZ;
    while(!uart_readOccupancy(BSP_UART_TERMINAL))if(clint_getTime(BSP_CLINT)>deadline)stop("export handshake timeout");
    if(uart_read(BSP_UART_TERMINAL)!='S')stop("export handshake");
    for(uint32_t offset=0;offset<1228800;offset+=16){
        deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
        while(!(rz_status()&8u))if(!(rz_status()&1u) || clint_getTime(BSP_CLINT)>deadline)stop("export DMA timeout");
        const uint32_t w[4]={opcode_R(CUSTOM0,2,65,0,0),opcode_R(CUSTOM0,3,65,0,0),
                             opcode_R(CUSTOM0,4,65,0,0),opcode_R(CUSTOM0,5,65,0,0)};
        for(unsigned k=0;k<4;k++)for(unsigned b=0;b<4;b++)uart_write(BSP_UART_TERMINAL,(char)(w[k]>>(b*8)));
        if(opcode_R(CUSTOM0,6,65,0,0)!=0)stop("export release");
    }
    uint32_t bad=opcode_R(CUSTOM0,1,65,0,0);
    bsp_uDelay(20000);
    write_u32(SYSTEM_CLINT_HZ/(BSP_UART_BAUDRATE*BSP_UART_DATA_LEN)-1,BSP_UART_TERMINAL+UART_CLOCK_DIVIDER);
    bsp_printf("IRIS STREAM END %s dummy_bad=%d\n",kind,bad);
    if(bad)stop("export dummy audit");
}
#if !IRIS_STREAM_SNAPSHOT
// Drain diagnostics only when the UART FIFO has room. Printing must never
// hold up capture arming or a VS commit at the end of a video frame.
static char log_buffer[512];
static unsigned log_size,log_sent;
static void log_text(const char *s){
    while(*s && log_size<sizeof(log_buffer))log_buffer[log_size++]=*s++;
}
static void log_number(uint32_t v){
    char digits[10];unsigned n=0;
    do{digits[n++]=(char)('0'+v%10);v/=10;}while(v);
    while(n && log_size<sizeof(log_buffer))log_buffer[log_size++]=digits[--n];
}
static void log_field(const char *name,uint32_t v){log_text(name);log_number(v);}
static void log_pump(void){
    unsigned available=uart_writeAvailability(BSP_UART_TERMINAL);
    while(log_sent<log_size && available--)
        uart_write(BSP_UART_TERMINAL,log_buffer[log_sent++]);
    if(log_sent==log_size)log_sent=log_size=0;
}
static void run_pipeline(volatile uint32_t *demo,uint32_t ink_supported){
    enum {FREE,CAPTURING,CAPTURED,INFERENCING,COMPLETE,PENDING,DISPLAYED};
    unsigned state[3]={FREE,FREE,FREE};
    const uint32_t input[3]={0x03000000u,0x03200000u,0x03800000u};
    const uint32_t output[3]={0x03400000u,0x03600000u,0x03a00000u};
    static uint64_t capture_begin[3];
    uint64_t invoke_begin=0,commit_begin=0,last_display=0;
    uint64_t previous=clint_getTime(BSP_CLINT);
    static uint32_t capture_ticks[3],invoke_ticks[3],overlap_ticks[3];
    uint32_t sequence=0,rejects=demo[8];
    int capture=-1,inference=-1,pending=-1,display=-1;
    if(demo[16]!=0x49500301u || (demo[19]&4u))stop("pipeline must start without a displayed bank");
    for(;;){
        const uint64_t now=clint_getTime(BSP_CLINT);
        if(capture>=0 && inference>=0)overlap_ticks[inference]+=(uint32_t)(now-previous);
        previous=now;
        const uint32_t status=demo[0];
        if(demo[8]!=rejects || demo[6] || demo[7] || demo[10] || demo[11])stop("pipeline data/ownership error");
        if(capture>=0){
            if((status&7u)==6u)stop("pipeline capture error");
            if(now-capture_begin[capture]>SYSTEM_CLINT_HZ)stop("pipeline capture timeout");
            if(demo[17]&(1u<<capture)){
                // Completion can arrive between the earlier status read and
                // the valid bitmap read; audit a fresh status snapshot.
                if((demo[0]&7u)!=2u || demo[20]!=(uint32_t)capture)stop("pipeline capture audit");
                capture_ticks[capture]=(uint32_t)(now-capture_begin[capture]);
                state[capture]=CAPTURED;capture=-1;
            }
        }
        if(inference>=0){
            if(now-invoke_begin>SYSTEM_CLINT_HZ)stop("pipeline CNN timeout");
            if(irq_seen){
                if((irq_status&7u)!=2u || (cnn_status()&7u)!=0 ||
                   opcode_R(CUSTOM0,0,73,0,0)!=0 || opcode_R(CUSTOM0,1,73,0,0)!=76800 ||
                   opcode_R(CUSTOM0,2,73,0,0)!=76800)stop("pipeline CNN result audit");
                for(unsigned layer=0;layer<3;layer++)
                    if(opcode_R(CUSTOM0,3,72,layer,0)!=76800)stop("incomplete CNN layer");
                invoke_ticks[inference]=(uint32_t)(now-invoke_begin);
                demo[18]=(uint32_t)inference;
                if(demo[18]&4u)stop("inference lease release failed");
                state[inference]=COMPLETE;inference=-1;
            }
        }
        if(pending>=0){
            if(now-commit_begin>SYSTEM_CLINT_HZ)stop("pipeline VS timeout");
            if(!(status&32u)){
                if(demo[19]!=(4u|(uint32_t)pending) || demo[4]!=sequence+1)stop("pipeline VS ownership audit");
                if(display>=0)state[display]=FREE;
                display=pending;pending=-1;state[display]=DISPLAYED;sequence++;
                const uint32_t commit_ticks=(uint32_t)(now-commit_begin);
                const uint32_t period_ticks=last_display ? (uint32_t)(now-last_display) : 0;
                last_display=now;
                iris_stream_control[1]=sequence;iris_stream_control[2]=invoke_ticks[display];
                iris_stream_control[3]=demo[4];iris_stream_control[5]=capture_ticks[display];
                iris_stream_control[6]=commit_ticks;iris_stream_control[7]=period_ticks;
                iris_stream_control[8]=overlap_ticks[display];
                if((sequence==1 || sequence%30==0) && !log_size){
                    log_field("IRIS LIVE frame=",sequence);log_field(" pair=",(uint32_t)display);
                    log_field(" Invoke_ticks=",invoke_ticks[display]);log_field(" displayed=",demo[4]);
                    log_field(" captures=",demo[5]);log_field(" underflow=",demo[6]);
                    log_field(" readerr=",demo[7]);log_field(" rejects=",demo[8]);log_text("\n");
                    log_field("IRIS PERF frame=",sequence);log_field(" capture_ticks=",capture_ticks[display]);
                    log_field(" invoke_ticks=",invoke_ticks[display]);log_field(" commit_ticks=",commit_ticks);
                    log_field(" period_ticks=",period_ticks);log_field(" overlap_ticks=",overlap_ticks[display]);log_text("\n");
                }
            }
        }
        if(pending<0)for(unsigned bank=0;bank<3;bank++)if(state[bank]==COMPLETE){
            demo[1]=bank;demo[0]=2;commit_begin=clint_getTime(BSP_CLINT);
            state[bank]=PENDING;pending=(int)bank;break;
        }
        if(inference<0)for(unsigned bank=0;bank<3;bank++)if(state[bank]==CAPTURED){
            demo[18]=4u|bank;
            if(demo[18]!=(4u|bank))stop("inference lease acquisition failed");
            irq_seen=0;irq_status=0;overlap_ticks[bank]=0;
            if(opcode_R(CUSTOM0,1,72,input[bank],output[bank])!=0)stop("CNN address config");
            invoke_begin=clint_getTime(BSP_CLINT);
            if(opcode_R(CUSTOM0,5,72,0,0)!=0)stop("CNN start rejected");
            state[bank]=INFERENCING;inference=(int)bank;break;
        }
        if(capture<0)for(unsigned bank=0;bank<3;bank++)if(state[bank]==FREE){
            demo[1]=bank;
            if(demo[2]!=input[bank] || demo[3]!=output[bank])stop("pipeline bank address mismatch");
            flush();demo[0]=1;capture_begin[bank]=clint_getTime(BSP_CLINT);
            state[bank]=CAPTURING;capture=(int)bank;break;
        }
        if(ink_supported && !(demo[14]&1u) && uart_readOccupancy(BSP_UART_TERMINAL)){
            const char command=uart_read(BSP_UART_TERMINAL);uint32_t mode=4;
            if(command=='n')mode=0;else if(command=='c')mode=1;
            else if(command=='h')mode=2;else if(command=='s')mode=3;
            if(mode<4){
                demo[13]=mode;
                if(!log_size){log_field("IRIS INK requested=",mode);log_text("\n");}
            }
        }
        if(ink_supported)iris_stream_control[4]=demo[13];
        iris_stream_control[0]=0x100u|(capture>=0 ? 1u : 0)|(inference>=0 ? 2u : 0)|(pending>=0 ? 4u : 0);
        log_pump();
    }
}
#endif
int main(void){
    bsp_init();iris_stream_control[0]=1;
    bsp_printf("IRIS STREAM CNN: 640x480 C4; DDR triple-buffer pipeline; 100MHz timing ticks\n");
    if(opcode_R(CUSTOM0,0,72,0,0)!=0x49430101u || opcode_R(CUSTOM0,2,72,0,0)!=0x01e00280u)stop("CNN ABI mismatch");
    for(unsigned layer=0;layer<3;layer++)for(unsigned k=0;k<52;k++)
        if(opcode_R(CUSTOM0,4,72,(layer<<8)|k,iris_cnn_parameters[layer][k])!=0)stop("weight deployment failed");
    if((cnn_status()&8u)==0)stop("CNN parameters incomplete");
    plic_set_threshold(BSP_PLIC,BSP_PLIC_CPU_0,0);
    plic_set_priority(BSP_PLIC,SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT,1);
    plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT,1);
    csr_write(mie,MIE_MEIE);csr_set(mstatus,MSTATUS_MIE);
    volatile uint32_t *demo=(volatile uint32_t *)0xf8100000u;
    if((demo[0]>>16)!=0x4953 || demo[9]!=0x00030002)stop("camera/display ABI mismatch");
    const uint32_t ink_supported=demo[15]==0x494b0001u || demo[15]==0x494b0002u;
    if(ink_supported)bsp_printf("IRIS INK mode=%d; UART n=original c=contrast h=contour s=strong; VS-applied ABI=%x\n",demo[13],demo[15]);
#if !IRIS_STREAM_SNAPSHOT
    run_pipeline(demo,ink_supported);
#else
    for(uint32_t sequence=1;;sequence++){
        uint64_t deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
        while(demo[0]&32u)if(clint_getTime(BSP_CLINT)>deadline)stop("pair acknowledgement timeout");
        // Exercise the new third DDR pair in the strict snapshot build.
        const uint32_t pair=2u;
        demo[1]=pair;const uint32_t input=demo[2],output=demo[3],rejects=demo[8];
        if(input!=0x03800000u || output!=0x03a00000u)stop("bank address mismatch");
        iris_stream_control[0]=2;flush();demo[0]=1;
        deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
        while(!(demo[0]&1u))if(demo[8]!=rejects || clint_getTime(BSP_CLINT)>deadline)stop("capture start failed");
        while(demo[0]&1u)if(clint_getTime(BSP_CLINT)>deadline)stop("capture timeout");
        if((demo[0]&7u)!=2u || demo[10] || demo[11])stop("capture payload audit");
        if(sequence==1)bsp_printf("IRIS CAPTURE AUDIT source_dummy=%d bus_dummy=%d serial_ddr=%d\n",demo[10],demo[11],demo[12]);
#if IRIS_STREAM_SNAPSHOT
        export_frame(input,"input");
#endif
        irq_seen=0;irq_status=0;iris_stream_control[0]=3;
        if(opcode_R(CUSTOM0,1,72,input,output)!=0)stop("CNN address config");
        const uint64_t begin=clint_getTime(BSP_CLINT);
        if(opcode_R(CUSTOM0,5,72,0,0)!=0)stop("CNN start rejected");
        while(!irq_seen)if(clint_getTime(BSP_CLINT)-begin>SYSTEM_CLINT_HZ){
            opcode_R(CUSTOM0,7,72,0,0);stop("CNN completion timeout");
        }
        const uint32_t ticks=(uint32_t)(clint_getTime(BSP_CLINT)-begin);
        if((irq_status&7u)!=2u || (cnn_status()&7u)!=0 || opcode_R(CUSTOM0,0,73,0,0)!=0 ||
           opcode_R(CUSTOM0,1,73,0,0)!=76800 || opcode_R(CUSTOM0,2,73,0,0)!=76800)stop("CNN result audit");
        for(unsigned layer=0;layer<3;layer++)if(opcode_R(CUSTOM0,3,72,layer,0)!=76800)stop("incomplete CNN layer");
        iris_stream_control[0]=4;demo[0]=2;
        deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
        while(demo[0]&32u)if(clint_getTime(BSP_CLINT)>deadline)stop("display commit timeout");
        if(demo[8]!=rejects || demo[6] || demo[7])stop("display error");
        iris_stream_control[1]=sequence;iris_stream_control[2]=ticks;iris_stream_control[3]=demo[4];
#if !IRIS_STREAM_SNAPSHOT
        // One command per completed frame; the mailbox stays stable until VS.
        if(ink_supported && !(demo[14]&1u) && uart_readOccupancy(BSP_UART_TERMINAL)){
            const char command=uart_read(BSP_UART_TERMINAL);
            uint32_t mode=4;
            if(command=='n')mode=0;else if(command=='c')mode=1;
            else if(command=='h')mode=2;else if(command=='s')mode=3;
            if(mode<4){demo[13]=mode;bsp_printf("IRIS INK requested=%d command=%c\n",mode,command);}
        }
        if(ink_supported)iris_stream_control[4]=demo[13];
#endif
        // UART is diagnostic, not part of the pixel path. Sparse logging
        // avoids spending ~12ms printing every newly committed frame.
        if(sequence==1 || sequence%30==0)bsp_printf("IRIS LIVE frame=%d pair=%d Invoke_ticks=%d displayed=%d captures=%d underflow=%d readerr=%d rejects=%d\n",
            sequence,pair,ticks,demo[4],demo[5],demo[6],demo[7],demo[8]);
#if IRIS_STREAM_SNAPSHOT
        export_frame(output,"output");
        bsp_printf("IRIS STREAM DONE pair=%d displayed=%d\n",pair,demo[4]);
        iris_stream_control[0]=5;for(;;){}
#endif
    }
#endif
}
