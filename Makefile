#Makefile for Entropy Project

CC = gcc
CFLAGS = -c -Wall
LDFLAGS = 
CLIB = libpcap-1.6.2/
SRC = entropy.c pcap.c
HDR = pcap.h
OBJECTS = $(SRC:.c=.o)
EXE = entropy

all: $(SRC) $(EXE) 

$(EXE): $(OBJECTS)
	$(CC) $(LDFLAGS) $(OBJECTS) -o $@

.c.o:
	$(CC) $(CLFAGS) $< -o $@ 

clean:
	rm -f *.o


