# Calculating Average time taken for operations 

# compile using our GCC wrapper
/path/to/oblivcc <operation_file> basic.oc -I .

# run: Shell script to calculate the specified operation. Runs for 200 times with input values as (33i+i*i) for party 1 and (i*i) for party 2 and stores the output values in output_values.txt 
sh execute.sh

To calculate the average run the c file calculate_avg.c
gcc -o avg calculate_avg.c 
./avg

Sample output will look like:
Number of samples taken: 200
Average execution time: 209.594ms
Number of gates used: 31
