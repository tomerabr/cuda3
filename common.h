#pragma once

#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

///////////////////////////////////////////////// DO NOT CHANGE ///////////////////////////////////////

#define IMG_DIMENSION 32
#define OUTSTANDING_REQUESTS 100

#define SQR(a) ((a) * (a))

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned char uchar;

double static inline get_time_msec(void) {
    struct timespec t;
    int res = clock_gettime(CLOCK_MONOTONIC, &t);
    if (res) {
        perror("clock_gettime failed");
        exit(1);
    }
    return t.tv_sec * 1e+3 + t.tv_nsec * 1e-6;
}

struct rpc_request
{
    int request_id; /* Returned to the client via RDMA write immediate value; use -1 to terminate */

    /* Input buffer */
    int input_rkey;
    int input_length;
    uint64_t input_addr;

    /* Output buffer */
    int output_rkey;
    int output_length;
    uint64_t output_addr;
};

#define IB_PORT_SERVER 1
#define IB_PORT_CLIENT 2

/////////////////////////////////////////////////////////////////////////////////////////////////////

struct ib_info_t {
    int lid;
    int qpn;
    /* TODO add additional server rkeys / addresses here if needed */
	int request_rkey;
    int response_rkey;
    uintptr_t request_buffer_addr;
    uintptr_t response_buffer_addr;

    /* TODO communicate number of queues / blocks, other information needed to operate the GPU queues remotely */
	int TB_size;
};

typedef struct _buffer {
	volatile int head;
	volatile int tail;
	volatile int flag;
	volatile int img_id[10];
	uchar queue[10][SQR(IMG_DIMENSION)];
}buffer;

enum mode_enum {
    MODE_RPC_SERVER,
    MODE_QUEUE,
};

void parse_arguments(int argc, char **argv, enum mode_enum *mode, int *tcp_port);

#ifdef __cplusplus
}
#endif
