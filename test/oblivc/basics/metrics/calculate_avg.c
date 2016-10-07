#include <stdio.h>
#include <stdlib.h>
#include <math.h>

int main() {

    int i, gate, res;
    float runtime, avg = 0;
    FILE *fp;
    char line[1024];
    int count = 0;

    fp = fopen("output_values.txt", "r");

    for(i=0; i<200; i++){
       fgets(line, sizeof(line), fp); 
       sscanf(line, "%f %d %d", &runtime, &gate, &res);
       avg = avg + runtime;
       count++;
    }

    printf("Number of samples taken: %d\n", count);
    printf("Average execution time: %.3fms\n", (avg/count));
    printf("Number of gates used: %d\n", gate);
       
    return (0);

}
    
