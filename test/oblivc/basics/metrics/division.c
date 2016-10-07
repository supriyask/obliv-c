#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <assert.h>
#include "basic.h"
#include <obliv.h>
#include "../../common/util.h"
#include "dbg.h"

struct timeval start, end, result;
int currentParty, gates;
double runtime;

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

    /* Division */
    gettimeofday(&start, NULL);

    // Execute Yao protocol and cleanup
    execYaoProtocol(&pd, division, &io); // starts 'division()'
    gettimeofday(&end, NULL);
    cleanupProtocol(&pd);
    gates = yaoGateCount();

    runtime = time_delta(start, end);

    if (currentParty == 2) 
      printf("%.3f %d %d\n", runtime, gates, io.res);

  } else {
    log_info("Usage: %s <hostname:port> <1|2> <value>\n"
             "\tHostname usage:\n"
             "\tlocal -> 'localhost' remote -> IP address or DNS name\n", argv[0]);
  }
  return 0;
}

