# Basic Arithmetic Operations 
Secure MPC version of arithmetic operations using [Obliv-C language](http://www.oblivc.org);

# Usage Notes
Calulates division of two integer values provided by the parties over TCP connection. Firat party's value will be divided by the second party's value.

# compile using our GCC wrapper
/path/to/oblivcc div.c div.oc -I .

# run: party 1 provides hostname, port number and input value and waits for party 2 connection. 
Usage: ./a.out <hostname:port> <1|2> <value>

Does not compute data values over 32,000 currently. Adjust implementation for long long ints if needed.
     
If using EC2 on AWS to compute data:
Add desired TCP port as a custom inbound rule to each AMI nodes' security group before running. Use Public IP or DNS name for hostname in runtime argument.
