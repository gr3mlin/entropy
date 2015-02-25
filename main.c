/*
* Shannon Entropy Based Spatial Clustering of [Packet] Application with Noise
* DATE: 4 FEB 2015
* AUTHOR: GR3MLIN
*
* This program opens a promiscious network session, calculates the entropy of the datagram, and saves it to a file.
*
*/

#include <signal.h>
#include <unistd.h>
#include <pcap.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <netinet/if_ether.h>  /* includes net/ethernet.h */
#include "disorder.c" //Use this for now because this library is better than my implementation.

#define MAXLEN 1522 //maximum string length allowed by ethernet frame

pcap_t *handle;                /* Session handle */
char *dev;                     /* The device to sniff on usually eth0*/
char errbuf[PCAP_ERRBUF_SIZE]; /* Error string */
struct bpf_program filter;     /* The compiled filter */
char filter_app[] = "";        /* The filter expression if you want one*/
bpf_u_int32 mask;              /* Our netmask */
bpf_u_int32 net;               /* Our IP */
struct pcap_pkthdr header;     /* The header that pcap gives us */
const u_char *packet;          /* The actual packet */
struct ether_header *eptr;     /* net/ethernet.h */
u_char packetBody[MAXLEN];
FILE *file;
float entropy = 0.0;

//CTRL-C Handler
void close_handler(int s){
           //printf(" Closing\n",s);
           //fclose(file);
           exit(0); 
}


/* Define Callback Function: 
void callback_fnct(u_char *args, const struct pcap_pkthdr *header, const u_char *packet); */
void callback(u_char *trash, const struct pcap_pkthdr *passed_header, const u_char *passed_packet)
{
    static long count = 1;
    int intPktLength = passed_header->len;
    //printf("Time: %ld.%ld\n", passed_header->ts.tv_sec, passed_header->ts.tv_usec);
    //printf("Captured a packet with length of [%d]\n", intPktLength);
    eptr = (struct ether_header *) passed_packet;
    //if (ntohs (eptr->ether_type) == ETHERTYPE_IP){
    //        printf("This is an IP packet\n");
    //    }

    int intpktLengthCounter = 6; //First 6 Bytes are PCAP added stuff.. I think time? I need to look that up. For now just chop it off
    
    //Print packet in bytes
    while(intpktLengthCounter <= intPktLength) {
        packetBody[intpktLengthCounter-6] = passed_packet[intpktLengthCounter];
        //printf("%x ", packetBody[intpktLengthCounter-6]);
        intpktLengthCounter++;
    }

    u_char *ptrpacketBody = NULL;

    ptrpacketBody = &packetBody[0];
    
    entropy = shannon_H(ptrpacketBody,(long) intPktLength);
    
    //printf("\nPacket Body Entropy: %f\n", entropy);
    //printf("Packet count: %d\n", count);
    
    //fprintf(file,"%ld, %ld.%ld, %d, ", count, passed_header->ts.tv_sec, passed_header->ts.tv_usec, passed_header->len);
    int i=0;
    
    /*while(i <= intkPktLength){
        fprintf(file,"%x, ", packetBody[i]);
        i++;
    }
    */
    //fprintf(file, "%d, %f\n", passed_header->len, entropy);
    printf("0:%d\n", passed_header->len);
    printf("1:%f\n", entropy);
    fflush(stdout);
    count++;
}


int main(int argc, char **argv)
{
    struct sigaction sigIntHandler;
    sigIntHandler.sa_handler = close_handler;
    sigemptyset(&sigIntHandler.sa_mask);
    sigIntHandler.sa_flags = 0;
    sigaction(SIGINT, &sigIntHandler, NULL);

    if(argc != 2)
    {
        //printf("No filter applied\n");
    }

    /* Define the device */
    dev = pcap_lookupdev(errbuf);
    if (dev == NULL) {
        printf("Couldn't find the default device: %s\n, are you sudo?", errbuf);
        return(2);
    }
    //printf("Successfully Opened: %s\n", dev);

    /* Find the properties for the device */
    pcap_lookupnet(dev, &net, &mask, errbuf);

    /* Open the session in promiscuous mode, run until fault */
    handle = pcap_open_live(dev, BUFSIZ, 1, 0, errbuf);

    /* Compile and apply the filter */
    pcap_compile(handle, &filter, filter_app, 0, net);
    pcap_setfilter(handle, &filter);

    /* Initialize the file we will write too */
    //file = fopen("capture.txt", "w"); //define the filename as an argv
    //fprintf(file,"Packet#, Time, Packet Length, Entropy\n");
    //if (file==NULL){
        //printf("Error opening file\n");
        //return(1);
    //}


    /* Grab a packet */
    //packet = pcap_next(handle, &header);
    pcap_loop(handle, 0, callback, NULL);

    /* Print its length */
    //printf("Recieved a packet with length of [%d]\n", header.len);

    /* And close the session */
    pcap_close(handle);
    return(0);
}
