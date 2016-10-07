#!/bin/bash

port=2222;
a=0;
b=0;

for i in `seq 1 200`;
do
    a=$(( $i*33 + $i * $i ));
    ./a.out localhost:$port 1 $a &

    sleep 1

    b=$(( $i * $i ));
    line=$(./a.out localhost:$port 2 $b)

    echo $line >> output_values.txt

    port=$(( $port + 10 ));
    sleep 1

done;   

