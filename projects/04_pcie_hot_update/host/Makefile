# Linux build of the pcie_hot_update host tool.
#   make            -> ./pcie_hot_update
#   sudo ./pcie_hot_update info
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c99

pcie_hot_update: pcie_hot_update.c bar_linux.c sha256.c bar_access.h sha256.h
	$(CC) $(CFLAGS) -o $@ pcie_hot_update.c bar_linux.c sha256.c

clean:
	rm -f pcie_hot_update

.PHONY: clean
