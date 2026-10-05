// Bare-metal crt compatibility for the xPack riscv-none-elf-gcc toolchain.
// libstdc++'s eh_globals.o references __dso_handle even when the application
// builds with -fno-use-cxa-atexit; the toolchain only emits __dso_handle from
// crtbegin for hosted/shared links. A null handle is correct for a single
// statically linked bare-metal image (atexit keys collapse to one program).
extern "C" void *__dso_handle = 0;
