# Linux build of the fpga1768 host tool.
#   make -C host          -> host/fpga1768
#   sudo host/fpga1768 info
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c99

SRCS = fpga1768.c ddr.c bar_linux.c sha256.c
HDRS = bar_access.h sha256.h tool.h

fpga1768: $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ $(SRCS)

clean:
	rm -f fpga1768

.PHONY: clean
