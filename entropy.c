#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>
 
#define MAXLEN 100 //maximum string length
 
int makehist(char *S,int *hist,int len){
	int wherechar[256];
	int i,histlen;
	histlen=0;
	for(i=0;i<256;i++)wherechar[i]=-1;
	for(i=0;i<len;i++){
		if(wherechar[(int)S[i]]==-1){
			wherechar[(int)S[i]]=histlen;
			histlen++;
		}
		hist[wherechar[(int)S[i]]]++;
	}
	//for(i=0;i<256;i++){
	//	printf("%d ",wherechar[i]);
	//}
	//printf("Histlength: %d\n",histlen);
	return histlen;
}
 
double entropy(int *hist,int histlen,int len){
	int i;
	double H;
	H=0;
	for(i=0;i<histlen;i++){
		H-=(double)hist[i]/len*log2((double)hist[i]/len);
	}
	return H;
}
 
float strToEntropy(u_char *string, int length){
	//char S[MAXLEN];
	int len,*hist,histlen;
	double H;
	//scanf("%[^\n]",S);
	len=strlen(string);
	hist=(int*)calloc(len,sizeof(int));
	histlen=makehist(string,hist,len);
	//hist now has no order (known to the program) but that doesn't matter
	H=entropy(hist,histlen,len);
	//printf("%lf\n",H);
	return H;
}

void main(){
	//char string[MAXLEN];
	int length;
	double H;
	u_char string[] = {1, 2, 2, 3, 3, 3, 4, 4, 4, 4}; //example string
	length = strlen(string)-1;
	string[length]=NULL;
	printf("String length is: %d\n", length);
	H = strToEntropy(string, length);
	printf("%lf\n",H);
}