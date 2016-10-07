#pragma once


typedef struct protocolIO
{
  int n;
  int res;
  
} protocolIO;

void sum(void* args);
void sub(void* args);
void mul(void* args);
void division(void* args);

const char* mySide();
