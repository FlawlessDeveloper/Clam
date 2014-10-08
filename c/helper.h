#pragma once

#if __GNUC__
#define UNUSED __attribute__((__unused__))
#else
#define UNUSED
#endif

const char* sgetenv(const char* name, const char* defaultValue);
int PrintErrImpl(int errcode, const char* message, const char* filename, int line);

#define PrintErr(errcode) PrintErrImpl((errcode), (#errcode), __FILE__, __LINE__)
