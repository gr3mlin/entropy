#Makefile for Entropy Project

CC = gcc
CFLAGS = -c -Wall
LDFLAGS = -lm -lpcap
SRC = main.c
EXE = main

all: 
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRC) -o $(EXE)

clean:
	rm -f *.o


