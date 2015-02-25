README

Description of Project:
In certain networks it may be useful to analyze network traffic for abnormal behavior. One method of doing this that is not signature based is to calculate the entropy of the datagrams across an ethernet network and then graph them relative to their size. We want to include the entire datagram because abnormalities in the header may be of interest. After graphing the data it is useful to use unsupervised machine learning algorithms to identify noise. One such common method is DBSCAN. Other supervised and unsupervised methods may be used in place or in conjunction with this technique in order to analyze the dataset and prioritize human analysis.

INSTALL

You will need to compile the following files with gcc or a suitable compiler against your target system:
main.c
entrop

When compiling dont forget to add the -lm and -lpcap flag!

Example:
gcc main.c -lm -lpcap -o main

Run:
sudo ./main or you will crash and/or not open the interface.



Notes:
Live Plotting:
sudo ./main | perl ../driveGnuPlots.pl 2 50 50 "Size" "Entropy"



RESOURCES:
DBSCAN
http://en.wikibooks.org/wiki/Data_Mining_Algorithms_In_R/Clustering/Density-Based_Clustering
http://staffwww.itn.liu.se/~aidvi/courses/06/dm/Seminars2011/DBSCAN(4).pdf
http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.88.4045&rep=rep1&type=pdf
SHANNON ENTROPY
http://rosettacode.org/wiki/Entropy#C
PCAP
http://www.tcpdump.org/pcap.html

