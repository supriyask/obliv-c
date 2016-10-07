#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <assert.h>
#include "sub.h"
#include <obliv.h>
#include "../../common/util.h"
#include "dbg.h"

struct timeval start, end, result;
int currentParty;

const char* mySide() {
  if (currentParty == 1) return "Generator";
  else return "Evaluator";
}

double time_delta(struct timeval start, struct timeval end){
    double output = 0.0;
    result.tv_sec = end.tv_sec - start.tv_sec;
    result.tv_usec = end.tv_usec - start.tv_usec;
    if (result.tv_usec < 0) {
        --result.tv_sec;
        result.tv_usec += 1000000;
    }
    output = (result.tv_sec * 1000000 + result.tv_usec)/1000.0;
    return output;
}

int main(int argc, char *argv[]) {

  // Check args
  if (argc == 4) {
    // Initialize protocols and obtain connection information
    const char *remote_host = strtok(argv[1], ":");
    const char *port = strtok(NULL, ":");
    ProtocolDesc pd;
    protocolIO io;

    // Make connection between two shells
    // Modified ocTestUtilTcpOrDie() function from obliv-c/test/oblivc/common/util.c
    log_info("\nConnecting to %s on port %s ...\n", remote_host, port);
    if(argv[2][0] == '1') {
      if(protocolAcceptTcp2P(&pd,port)!=0) {
        log_err("TCP accept from %s failed\n", remote_host);
        exit(1);
      }
    }
    else {
      if(protocolConnectTcp2P(&pd,remote_host,port)!=0) {
        log_err("TCP connect to %s failed\n", remote_host);
        exit(1);
        }
    }

    // Final initializations before entering Yao protocol
    currentParty = (argv[2][0]=='1'?1:2);
    setCurrentParty(&pd, currentParty); // only checks for a '1'
    io.n = atoi(argv[3]); // value
    gettimeofday(&start, NULL);

    // Execute Yao protocol and cleanup
    execYaoProtocol(&pd, sub, &io); // starts 'sub()'
    gettimeofday(&end, NULL);
    cleanupProtocol(&pd);

    double runtime = time_delta(start, end);
    // Print results and store runtime data
    log_info("%s total time: %.3fms\n", mySide(), runtime);

    int gates = yaoGateCount();
    log_info("Result: %d\n", io.res);
    log_info("Yao Gate Count: %u\n", gates);
    
    printf("\n");
  } else {
    log_info("Usage: %s <hostname:port> <1|2> <value>\n"
             "\tHostname usage:\n"
             "\tlocal -> 'localhost' remote -> IP address or DNS name\n", argv[0]);
  }
  return 0;
}

