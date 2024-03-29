#include <infiniband/verbs.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <string.h>
#include <assert.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include "common.h"

///////////////////////////////////////////////// DO NOT CHANGE ///////////////////////////////////////

#define TCP_PORT_OFFSET 23456
#define TCP_PORT_RANGE 1000

#define CUDA_CHECK(f) do {                                                                  \
    cudaError_t e = f;                                                                      \
    if (e != cudaSuccess) {                                                                 \
        printf("Cuda failure %s:%d: '%s'\n", __FILE__, __LINE__, cudaGetErrorString(e));    \
        exit(1);                                                                            \
    }                                                                                       \
} while (0)

__device__ int arr_min(int arr[], int arr_size) {
    int tid = threadIdx.x;
    int rhs, lhs;

    for (int stride = 1; stride < arr_size; stride *= 2) {
        if (tid >= stride && tid < arr_size) {
            rhs = arr[tid - stride];
        }
        __syncthreads();
        if (tid >= stride && tid < arr_size) {
            lhs = arr[tid];
            if (rhs != 0) {
                if (lhs == 0)
                    arr[tid] = rhs;
                else
                    arr[tid] = min(arr[tid], rhs);
            }
        }
        __syncthreads();
    }

    int ret = arr[arr_size - 1];
    return ret;
}

__device__ void prefix_sum(int arr[], int arr_size) {
    int tid = threadIdx.x;
    int increment;

    for (int stride = 1; stride < min(blockDim.x, arr_size); stride *= 2) {
        if (tid >= stride && tid < arr_size) {
            increment = arr[tid - stride];
        }
        __syncthreads();
        if (tid >= stride && tid < arr_size) {
            arr[tid] += increment;
        }
        __syncthreads();
    }
}

__global__ void gpu_process_image(uchar *in, uchar *out) {
    __shared__ int histogram[256];
    __shared__ int hist_min[256];

    int tid = threadIdx.x;

    if (tid < 256) {
        histogram[tid] = 0;
    }
    __syncthreads();

    for (int i = tid; i < SQR(IMG_DIMENSION); i += blockDim.x)
        atomicAdd(&histogram[in[i]], 1);

    __syncthreads();

    prefix_sum(histogram, 256);

    if (tid < 256) {
        hist_min[tid] = histogram[tid];
    }
    __syncthreads();

    int cdf_min = arr_min(hist_min, 256);

    __shared__ uchar map[256];
    if (tid < 256) {
        int map_value = (float)(histogram[tid] - cdf_min) / (SQR(IMG_DIMENSION) - cdf_min) * 255;
        map[tid] = (uchar)map_value;
    }

    __syncthreads();

    for (int i = tid; i < SQR(IMG_DIMENSION); i += blockDim.x) {
        out[i] = map[in[i]];
    }
    return;
}

/* TODO: copy queue-based GPU kernel from hw2 */

/* TODO: end */

void process_image_on_gpu(uchar *img_in, uchar *img_out)
{
    uchar *gpu_image_in, *gpu_image_out;
    CUDA_CHECK(cudaMalloc(&gpu_image_in, SQR(IMG_DIMENSION)));
    CUDA_CHECK(cudaMalloc(&gpu_image_out, SQR(IMG_DIMENSION)));

    CUDA_CHECK(cudaMemcpy(gpu_image_in, img_in, SQR(IMG_DIMENSION), cudaMemcpyHostToDevice));
    gpu_process_image<<<1, 1024>>>(gpu_image_in, gpu_image_out);
    CUDA_CHECK(cudaMemcpy(img_out, gpu_image_out, SQR(IMG_DIMENSION), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaDeviceSynchronize());

    CUDA_CHECK(cudaFree(gpu_image_in));
    CUDA_CHECK(cudaFree(gpu_image_out));
}

void print_usage_and_die(char *progname) {
    printf("usage: [port]\n");
    exit(1);
}

struct server_context {
    mode_enum mode;

    int tcp_port;
    int listen_fd; /* Listening socket for TCP connection */
    int socket_fd; /* Connected socket for TCP connection */

    rpc_request *requests; /* Array of outstanding requests received from the network */
    uchar *images_in; /* Input images for all outstanding requests */
    uchar *images_out; /* Output images for all outstanding requests */

    /* InfiniBand/verbs resources */
    struct ibv_context *context;
    struct ibv_cq *cq;
    struct ibv_pd *pd;
    struct ibv_qp *qp;
    struct ibv_mr *mr_requests; /* Memory region for RPC requests */
    struct ibv_mr *mr_images_in; /* Memory region for input images */
    struct ibv_mr *mr_images_out; /* Memory region for output images */
	
    /* TODO: add pointers and memory region(s) for CPU-GPU queues */
    struct ibv_mr *mr_queue_req;
    struct ibv_mr *mr_queue_res;
    buffer *ptr_arr_request;
    buffer *ptr_arr_response;
    int TB_size;
};

int get_threadblock_number_device( int device_number) {
	cudaDeviceProp prop;
	int max_threads_tb_nr;
	int max_shared_mem_tb_nr;
	int max_regs_tb_nr;
	int tb_nr = 0;

	CUDA_CHECK(cudaGetDeviceProperties(&prop, device_number));
	
	max_threads_tb_nr = prop.maxThreadsPerMultiProcessor / prop.maxThreadsPerBlock;
	max_shared_mem_tb_nr = prop.sharedMemPerMultiprocessor / SHARED_MEMORY_SZ_PER_TB;
	max_regs_tb_nr = prop.regsPerMultiprocessor / (KERNEL_MAX_REGISTERS * prop.maxThreadsPerBlock);

	tb_nr = (max_threads_tb_nr > max_shared_mem_tb_nr) ? max_shared_mem_tb_nr : max_threads_tb_nr;
	tb_nr = (tb_nr > max_regs_tb_nr) ? max_regs_tb_nr : tb_nr;

	return tb_nr * prop.multiProcessorCount;
}

int get_threadblock_number() {
	int min, devices_nr;

	CUDA_CHECK(cudaGetDeviceCount(&devices_nr));

	if (devices_nr <= 0)
		return 0;

	min = get_threadblock_number_device(0);
	for (int i = 1; i < devices_nr; i++) {
		int cur = get_threadblock_number_device(i);
		min = (cur < min) ? cur : min;
	}

	return min;
}

void allocate_memory(server_context *ctx)
{
    CUDA_CHECK(cudaHostAlloc(&ctx->images_in, OUTSTANDING_REQUESTS * SQR(IMG_DIMENSION), 0));
    CUDA_CHECK(cudaHostAlloc(&ctx->images_out, OUTSTANDING_REQUESTS * SQR(IMG_DIMENSION), 0));
    ctx->requests = (rpc_request *)calloc(OUTSTANDING_REQUESTS, sizeof(rpc_request));

    /* TODO take CPU-GPU stream allocation code from hw2 */
	int threadblock_num = get_threadblock_number();
	ctx->TB_size = threadblock_num;
    int TB_size = threadblock_num;
	
	cudaHostAlloc(&(ctx->ptr_arr_request),TB_size*sizeof(buffer),cudaHostAllocMapped);
    cudaHostAlloc(&(ctx->ptr_arr_response),TB_size*sizeof(buffer),cudaHostAllocMapped);
    for(int i = 0; i < TB_size; i++) {
    	ctx->ptr_arr_request[i].head = 0;
    	ctx->ptr_arr_request[i].tail = 0;
    	ctx->ptr_arr_request[i].flag = 0;
    	ctx->ptr_arr_response[i].head = 0;
    	ctx->ptr_arr_response[i].tail = 0;
    	ctx->ptr_arr_response[i].flag = -1;
    	for (int j = 0 ; j  < 10; j++) {
    		ctx->ptr_arr_response[i].img_id[j] = -1;
    		ctx->ptr_arr_request[i].img_id[j] = -1;
    	}
    }
}

void tcp_connection(server_context *ctx)
{
    /* setup a TCP connection for initial negotiation with client */
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) {
        perror("socket");
        exit(1);
    }
    ctx->listen_fd = lfd;

    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(struct sockaddr_in));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(ctx->tcp_port);

    if (bind(lfd, (struct sockaddr *)&server_addr, sizeof(struct sockaddr_in)) < 0) {
        perror("bind");
        exit(1);
    }

    if (listen(lfd, 1)) {
        perror("listen");
        exit(1);
    }

    printf("Server waiting on port %d. Client can connect\n", ctx->tcp_port);

    int sfd = accept(lfd, NULL, NULL);
    if (sfd < 0) {
        perror("accept");
        exit(1);
    }
    printf("client connected\n");
    ctx->socket_fd = sfd;
}

void initialize_verbs(server_context *ctx)
{
    /* get device list */
    struct ibv_device **device_list = ibv_get_device_list(NULL);
    if (!device_list) {
        printf("ERROR: ibv_get_device_list failed\n");
        exit(1);
    }

    /* select first (and only) device to work with */
    ctx->context = ibv_open_device(device_list[0]);

    /* create protection domain (PD) */
    ctx->pd = ibv_alloc_pd(ctx->context);
    if (!ctx->pd) {
        printf("ERROR: ibv_alloc_pd() failed\n");
        exit(1);
    }

    /* allocate a memory region for the RPC requests. */
    ctx->mr_requests = ibv_reg_mr(ctx->pd, ctx->requests, sizeof(rpc_request) * OUTSTANDING_REQUESTS, IBV_ACCESS_LOCAL_WRITE);
    if (!ctx->mr_requests) {
        printf("ibv_reg_mr() failed for requests\n");
        exit(1);
    }

    /* register a memory region for the input / output images. */
    ctx->mr_images_in = ibv_reg_mr(ctx->pd, ctx->images_in, OUTSTANDING_REQUESTS * SQR(IMG_DIMENSION), IBV_ACCESS_LOCAL_WRITE);
    if (!ctx->mr_images_in) {
        printf("ibv_reg_mr() failed for input images\n");
        exit(1);
    }

    /* register a memory region for the input / output images. */
    ctx->mr_images_out = ibv_reg_mr(ctx->pd, ctx->images_out, OUTSTANDING_REQUESTS * SQR(IMG_DIMENSION), IBV_ACCESS_LOCAL_WRITE);
    if (!ctx->mr_images_out) {
        printf("ibv_reg_mr() failed for output images\n");
        exit(1);
    }

    /* TODO register additional memory regions for CPU-GPU queues */
	ctx->mr_queue_req = ibv_reg_mr(ctx->pd, ctx->ptr_arr_request, sizeof(buffer)*ctx->TB_size, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ);
    if (!ctx->mr_queue_req) {
        printf("ibv_reg_mr() failed for queue_req\n");
        exit(1);
    }

    ctx->mr_queue_res = ibv_reg_mr(ctx->pd, ctx->ptr_arr_response, sizeof(buffer)*ctx->TB_size, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ);
    if (!ctx->mr_queue_res) {
        printf("ibv_reg_mr() failed for queue_res\n");
        exit(1);
    }

    /* create completion queue (CQ). We'll use same CQ for both send and receive parts of the QP */
    ctx->cq = ibv_create_cq(ctx->context, 2 * OUTSTANDING_REQUESTS, NULL, NULL, 0); /* create a CQ with place for two completions per request */
    if (!ctx->cq) {
        printf("ERROR: ibv_create_cq() failed\n");
        exit(1);
    }

    /* create QP */
    struct ibv_qp_init_attr qp_init_attr;
    memset(&qp_init_attr, 0, sizeof(struct ibv_qp_init_attr));
    qp_init_attr.send_cq = ctx->cq;
    qp_init_attr.recv_cq = ctx->cq;
    qp_init_attr.qp_type = IBV_QPT_RC; /* we'll use RC transport service, which supports RDMA */
    qp_init_attr.cap.max_send_wr = OUTSTANDING_REQUESTS; /* max of 1 WQE in-flight in SQ per request. that's enough for us */
    qp_init_attr.cap.max_recv_wr = OUTSTANDING_REQUESTS; /* max of 1 WQE in-flight in RQ per request. that's enough for us */
    qp_init_attr.cap.max_send_sge = 1; /* 1 SGE in each send WQE */
    qp_init_attr.cap.max_recv_sge = 1; /* 1 SGE in each recv WQE */
    ctx->qp = ibv_create_qp(ctx->pd, &qp_init_attr);
    if (!ctx->qp) {
        printf("ERROR: ibv_create_qp() failed\n");
        exit(1);
    }
}

void exchange_parameters(server_context *ctx, ib_info_t *client_info)
{
    /* ok, before we continue we need to get info about the client' QP, and send it info about ours.
     * namely: QP number, and LID.
     * we'll use the TCP socket for that */

    /* first query port for its LID (L2 address) */
    int ret;
    struct ibv_port_attr port_attr;
    ret = ibv_query_port(ctx->context, IB_PORT_SERVER, &port_attr);
    if (ret) {
        printf("ERROR: ibv_query_port() failed\n");
        exit(1);
    }

    /* now send our info to client */
    struct ib_info_t my_info;
    my_info.lid = port_attr.lid;
    my_info.qpn = ctx->qp->qp_num;
    /* TODO add additional server rkeys / addresses here if needed */
	my_info.request_buffer_addr = (uintptr_t)ctx->mr_queue_req->addr;
    my_info.request_rkey = ctx->mr_queue_req->rkey;
    my_info.response_buffer_addr = (uintptr_t)ctx->mr_queue_res->addr;
    my_info.response_rkey = ctx->mr_queue_res->rkey;
    my_info.TB_size = ctx->TB_size;

    ret = send(ctx->socket_fd, &my_info, sizeof(struct ib_info_t), 0);
    if (ret < 0) {
        perror("send");
        exit(1);
    }

    /* get client's info */
    recv(ctx->socket_fd, client_info, sizeof(struct ib_info_t), 0);
    if (ret < 0) {
        perror("recv");
        exit(1);
    }

    /* we don't need TCP anymore. kill the socket */
    close(ctx->socket_fd);
    close(ctx->listen_fd);
    ctx->socket_fd = ctx->listen_fd = 0;
}

/* Post a receive buffer of the given index (from the requests array) to the receive queue */
void post_recv(server_context *ctx, int index)
{
    struct ibv_recv_wr recv_wr = {}; /* this is the receive work request (the verb's representation for receive WQE) */
    ibv_sge sgl;

    recv_wr.wr_id = index;
    sgl.addr = (uintptr_t)&ctx->requests[index];
    sgl.length = sizeof(ctx->requests[0]);
    sgl.lkey = ctx->mr_requests->lkey;
    recv_wr.sg_list = &sgl;
    recv_wr.num_sge = 1;
    if (ibv_post_recv(ctx->qp, &recv_wr, NULL)) {
        printf("ERROR: ibv_post_recv() failed\n");
        exit(1);
    }
}

void connect_qp(server_context *ctx, ib_info_t *client_info)
{
    /* this is a multi-phase process, moving the state machine of the QP step by step
     * until we are ready */
    struct ibv_qp_attr qp_attr;

    /*QP state: RESET -> INIT */
    memset(&qp_attr, 0, sizeof(struct ibv_qp_attr));
    qp_attr.qp_state = IBV_QPS_INIT;
    qp_attr.pkey_index = 0;
    qp_attr.port_num = IB_PORT_SERVER;
    qp_attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ; /* we'll allow client to RDMA write and read on this QP */
    int ret = ibv_modify_qp(ctx->qp, &qp_attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);
    if (ret) {
        printf("ERROR: ibv_modify_qp() to INIT failed\n");
        exit(1);
    }

    /*QP: state: INIT -> RTR (Ready to Receive) */
    memset(&qp_attr, 0, sizeof(struct ibv_qp_attr));
    qp_attr.qp_state = IBV_QPS_RTR;
    qp_attr.path_mtu = IBV_MTU_4096;
    qp_attr.dest_qp_num = client_info->qpn; /* qp number of client */
    qp_attr.rq_psn      = 0 ;
    qp_attr.max_dest_rd_atomic = 1; /* max in-flight RDMA reads */
    qp_attr.min_rnr_timer = 12;
    qp_attr.ah_attr.is_global = 0; /* No Network Layer (L3) */
    qp_attr.ah_attr.dlid = client_info->lid; /* LID (L2 Address) of client */
    qp_attr.ah_attr.sl = 0;
    qp_attr.ah_attr.src_path_bits = 0;
    qp_attr.ah_attr.port_num = IB_PORT_SERVER;
    ret = ibv_modify_qp(ctx->qp, &qp_attr, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER);
    if (ret) {
        printf("ERROR: ibv_modify_qp() to RTR failed\n");
        exit(1);
    }

    /*QP: state: RTR -> RTS (Ready to Send) */
    memset(&qp_attr, 0, sizeof(struct ibv_qp_attr));
    qp_attr.qp_state = IBV_QPS_RTS;
    qp_attr.sq_psn = 0;
    qp_attr.timeout = 14;
    qp_attr.retry_cnt = 7;
    qp_attr.rnr_retry = 7;
    qp_attr.max_rd_atomic = 1;
    ret = ibv_modify_qp(ctx->qp, &qp_attr, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC);
    if (ret) {
        printf("ERROR: ibv_modify_qp() to RTS failed\n");
        exit(1);
    }

    /* now let's populate the receive QP with recv WQEs */
    for (int i = 0; i < OUTSTANDING_REQUESTS; i++) {
        post_recv(ctx, i);
    }
}

void event_loop(server_context *ctx)
{
    /* so the protocol goes like this:
     * 1. we'll wait for a CQE indicating that we got an Send request from the client.
     *    this tells us we have new work to do. The wr_id we used in post_recv tells us
     *    where the request is.
     * 2. now we send an RDMA Read to the client to retrieve the request.
     *    we will get a completion indicating the read has completed.
     * 3. we process the request on the GPU.
     * 4. upon completion, we send an RDMA Write with immediate to the client with
     *    the results.
     */

    struct ibv_send_wr send_wr;
    struct ibv_send_wr *bad_send_wr;
    rpc_request* req;
    uchar *img_in;
    uchar *img_out;
    ibv_sge sgl;

    bool terminate = false;

    while (!terminate) {
        /*step 1: poll for CQE */
        struct ibv_wc wc;
        int ncqes;
        do {
            ncqes = ibv_poll_cq(ctx->cq, 1, &wc);
        } while (ncqes == 0);
        if (ncqes < 0) {
            printf("ERROR: ibv_poll_cq() failed\n");
            exit(1);
        }
        if (wc.status != IBV_WC_SUCCESS) {
            printf("ERROR: got CQE with error '%s' (%d) (line %d)\n", ibv_wc_status_str(wc.status), wc.status, __LINE__);
            exit(1);
        }

        switch (wc.opcode) {
        case IBV_WC_RECV:
            /* Received a new request from the client */
            req = &ctx->requests[wc.wr_id];
            img_in = &ctx->images_in[wc.wr_id * SQR(IMG_DIMENSION)];

            /* Terminate signal */
            if (req->request_id == -1) {
                printf("Terminating...\n");
                terminate = true;
                break;
            }

            if (ctx->mode != MODE_RPC_SERVER) {
                printf("Got client RPC request when running in queue mode.\n");
                exit(1);
            }
            
            /* send RDMA Read to client to read the input */
            memset(&send_wr, 0, sizeof(struct ibv_send_wr));
            send_wr.wr_id = wc.wr_id;
            sgl.addr = (uintptr_t)img_in;
            sgl.length = req->input_length;
            sgl.lkey = ctx->mr_images_in->lkey;
            send_wr.sg_list = &sgl;
            send_wr.num_sge = 1;
            send_wr.opcode = IBV_WR_RDMA_READ;
            send_wr.send_flags = IBV_SEND_SIGNALED;
            send_wr.wr.rdma.remote_addr = req->input_addr;
            send_wr.wr.rdma.rkey = req->input_rkey;

            if (ibv_post_send(ctx->qp, &send_wr, &bad_send_wr)) {
                printf("ERROR: ibv_post_send() failed\n");
                exit(1);
            }
            break;

        case IBV_WC_RDMA_READ:
            /* Completed RDMA read for a request */
            req = &ctx->requests[wc.wr_id];
            img_in = &ctx->images_in[wc.wr_id * SQR(IMG_DIMENSION)];
            img_out = &ctx->images_out[wc.wr_id * SQR(IMG_DIMENSION)];

            process_image_on_gpu(img_in, img_out);
            
            /* send RDMA Write with immediate to client with the response */
            memset(&send_wr, 0, sizeof(struct ibv_send_wr));
            send_wr.wr_id = wc.wr_id;
            ibv_sge sgl;
            sgl.addr = (uintptr_t)img_out;
            sgl.length = req->output_length;
            sgl.lkey = ctx->mr_images_out->lkey;
            send_wr.sg_list = &sgl;
            send_wr.num_sge = 1;
            send_wr.opcode = IBV_WR_RDMA_WRITE_WITH_IMM;
            send_wr.send_flags = IBV_SEND_SIGNALED;
            send_wr.wr.rdma.remote_addr = req->output_addr;
            send_wr.wr.rdma.rkey = req->output_rkey;
            send_wr.imm_data = req->request_id;

            if (ibv_post_send(ctx->qp, &send_wr, &bad_send_wr)) {
                printf("ERROR: ibv_post_send() failed\n");
                exit(1);
            }
            break;

        case IBV_WC_RDMA_WRITE:
            /* Completed RDMA Write - reuse buffers for receiving the next requests */
            post_recv(ctx, wc.wr_id);

            break;
        default:
            printf("Unexpected completion\n");
            assert(false);
        }
    }
}

void teardown_context(server_context *ctx)
{
    /* cleanup */
    ibv_destroy_qp(ctx->qp);
    ibv_destroy_cq(ctx->cq);
    ibv_dereg_mr(ctx->mr_requests);
    ibv_dereg_mr(ctx->mr_images_in);
    ibv_dereg_mr(ctx->mr_images_out);
    /* TODO destroy the additional server MRs here if needed */
	ibv_dereg_mr(ctx->mr_queue_req);
    ibv_dereg_mr(ctx->mr_queue_res);
    CUDA_CHECK(cudaFreeHost((ctx->ptr_arr_response)));
	CUDA_CHECK(cudaFreeHost((ctx->ptr_arr_request)));
    ibv_dealloc_pd(ctx->pd);
    ibv_close_device(ctx->context);
}

int main(int argc, char *argv[]) {
    server_context ctx;

    parse_arguments(argc, argv, &ctx.mode, &ctx.tcp_port);
    if (!ctx.tcp_port) {
        srand(time(NULL));
        ctx.tcp_port = TCP_PORT_OFFSET + (rand() % TCP_PORT_RANGE); /* to avoid conflicts with other users of the machine */
    }

    /* Initialize memory and CUDA resources */
    allocate_memory(&ctx);

    /* Create a TCP connection with the client to exchange InfiniBand parameters */
    tcp_connection(&ctx);

    /* now that client has connected to us via TCP we'll open up some Infiniband resources and send it the parameters */
    initialize_verbs(&ctx);

    /* exchange InfiniBand parameters with the client */
    ib_info_t client_info;
    exchange_parameters(&ctx, &client_info);

    /* now need to connect the QP to the client's QP. */
    connect_qp(&ctx, &client_info);

    if (ctx.mode == MODE_QUEUE) {
        /* TODO run the GPU persistent kernel from hw2, for 1024 threads per block */
		for (int i = 0; i < ctx.TB_size; i++) {
    		gpu_process_image_queue<<<1, 1024>>>(ctx.ptr_arr_request, ctx.ptr_arr_response,i);
    	}
    }

    /* now finally we get to the actual work, in the event loop */
    /* The event loop can be used for queue mode for the termination message */
    event_loop(&ctx);

    printf("Done\n");

    teardown_context(&ctx);

    return 0;
}
