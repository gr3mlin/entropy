/*
* Shannon Entropy Based Spatial Clustering of [Packet] Application with Noise
* DATE: 4 FEB 2015
* AUTHOR: GR3MLIN
*
* This program opens a PCAP capture and calculated the entropy of the packet header and the full packet.
*
*/

#include <pcap.h>
#include <stdio.h>

pcap_t *handle;                /* Session handle */
char *dev;                     /* The device to sniff on */
char errbuf[PCAP_ERRBUF_SIZE]; /* Error string */
struct bpf_program filter;     /* The compiled filter */
char filter_app[] = "";        /* The filter expression */
bpf_u_int32 mask;              /* Our netmask */
bpf_u_int32 net;               /* Our IP */
struct pcap_pkthdr header;     /* The header that pcap gives us */
const u_char *packet;          /* The actual packet */

    /* Define Callback Function: 
    void callback_fnct(u_char *args, const struct pcap_pkthdr *header, const u_char *packet); */
void callback(u_char *trash, const struct pcap_pkthdr *passed_header, const u_char* passed_packet)
{
    static int count = 1;
    printf("Jacked a packet with length of [%d]\n", passed_packet);//Ok so at this point we recieve pointers to both the header and packet.. I dont understand why we dont get the header struct.. What I want to do at this point is save the size of the header, size of the packet, entropy of the header, and entropy of the packet to a file.
    printf("Packet count: %d\n", count);
    count++;
}


int main(int argc, char **argv)
{

    if(argc != 2)
    {
        printf("Jumble here about the filter");
    }

    /* Define the device */
    dev = pcap_lookupdev(errbuf);
    if (dev == NULL) {
        printf("Couldn't find the default device: %S\n", errbuf);
        return(2);
    }
    printf("Successfully Opened: %s\n", dev);

    /* Find the properties for the device */
    pcap_lookupnet(dev, &net, &mask, errbuf);

    /* Open the session in promiscuous mode, run until fault */
    handle = pcap_open_live(dev, BUFSIZ, 1, 0, errbuf);

    /* Compile and apply the filter */
    pcap_compile(handle, &filter, filter_app, 0, net);
    pcap_setfilter(handle, &filter);


    /* Grab a packet */
    //packet = pcap_next(handle, &header);
    pcap_loop(handle, 10, callback, NULL);

    /* Print its length */
    //printf("Recieved a packet with length of [%d]\n", header.len);

    /* And close the session */
    pcap_close(handle);
    return(0);
}
