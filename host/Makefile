# Linux build of the fpga1768 host tool.
#   make -C host          -> host/fpga1768
#   sudo host/fpga1768 info   (profiles: host/profiles, see README.md)
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c99

# Core, capability modules, Linux backend. Keep in sync with build.ps1.
SRCS = fpga1768.c core.c profile.c \
       cap_temp.c cap_pr.c cap_persona.c cap_ddr.c cap_flash.c cap_i2c.c \
       sha256.c bar_linux.c
HDRS = bar_access.h profile.h sha256.h tool.h

fpga1768: $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ $(SRCS)

clean:
	rm -f fpga1768

.PHONY: clean
