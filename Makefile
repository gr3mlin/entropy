#Makefile for Entropy Project

CC = gcc
CFLAGS = -c -Wall
LDFLAGS = -lm -lpcap
CLIB = libpcap-1.6.2/
SRC = entropy.c
HDR = pcap.h
OBJECTS = $(SRC:.c=.o)
EXE = entropy

all: $(SRC) $(EXE) 

$(EXE): $(OBJECTS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJECTS) -o $@

.c.o:
	$(CC) $(CLFAGS) $< -o $@ 

clean:
	rm -f *.o


