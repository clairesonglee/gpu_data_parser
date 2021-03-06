
#include <cstdint>
#include <iostream>
#include <fstream>
#include <string>
#include <chrono>
#include <cub/cub.cuh>

#include <stdio.h> 

using namespace std;

#define NUM_STATES 3
#define NUM_CHARS  256
#define NUM_THREADS 512
#define NUM_LINES 322
#define NUM_BLOCKS 30

#define BUFFER_SIZE 25000000
#define NUM_COMMAS 500
#define INPUT_FILE "./input_file.csv"
//#define INPUT_FILE "./taxi_input.txt"
#define CSV_FILE 1 // 1: csv file, 0: txt file


typedef std::chrono::high_resolution_clock Clock;

template <int states>
struct __align__(4) state_array{
    uint8_t v[states];

    __device__ state_array() {
        for(int i = 0; i < states; i++)
            v[i] = i;
    }

    __device__ void set_SA(int index, int x) {
       v[index] = x;
    }

};

typedef state_array<NUM_STATES> SA;

struct SA_op {
    __device__ SA operator()(SA &a, SA &b){
        SA c;
        for(int i = 0; i < NUM_STATES; i++) 
            c.v[i] = b.v[a.v[i]];
        
        return c;
    }
};

__global__
void remove_empty_elements (int** input, int* len_array, int total_lines, int* index, int* temp_base, 
                            int* offset_array,  int* output, int* output_line_num, int taxi_application) {

    __shared__ int line_num;
    __shared__ int base;

    int len;
    int block_num;


    if(threadIdx.x == 0) 
        line_num = atomicInc((unsigned int*) index, INT_MAX);
    __syncthreads();
    block_num =  line_num;

    

    while(block_num < total_lines) {

        len = len_array[block_num];


		if(threadIdx.x == 0)
			base = offset_array[block_num];
        __syncthreads();
        
        for(int loop = threadIdx.x; loop < len; loop += NUM_THREADS) {

        	if(!taxi_application) {
        		if(loop < len){
               		 output[base + loop] = (input[block_num])[loop];
        		}
        	}
        	else {
        		if(loop < len ){
        			output_line_num[base + loop] = block_num;
        			output[base + loop + 1] = (input[block_num])[loop] + 2;
        		}
        	}
        }

        if(threadIdx.x == 0) {
        	if(taxi_application){
        		output[base] = 0;
                output_line_num[base] = block_num;
            }
            free(input[block_num]);
            line_num = atomicInc((unsigned int*) index, INT_MAX);
        }
         __syncthreads();
        block_num =  line_num;
    }

}


__global__
void merge_scan (char* line, int* len_array, int* offset_array, int** output_array, 
                 int* index, int total_lines, int* num_commas_array, SA* d_SA_Table, int* total_num_commas, uint8_t* d_E, int taxi_application){


    typedef cub::BlockScan<SA, NUM_THREADS> BlockScan; // change name
    typedef cub::BlockScan<int, NUM_THREADS> BlockScan2; //

    __shared__ typename BlockScan::TempStorage temp_storage;
    __shared__ typename BlockScan2::TempStorage temp_storage2;
    __shared__ SA prev_value;
    __shared__ int prev_sum;
    __shared__ int line_num;

    SA temp_prev_val;
    int temp_prev_sum;

    int len, offset;
    int block_num;
    int start_state;

    int* temp_output_array;
    int temp_array_size;

    if(threadIdx.x == 0) {
        line_num = atomicInc((unsigned int*) index, INT_MAX);
    }
    __syncthreads();
    block_num =  line_num;

    while(block_num < total_lines ) {

        temp_array_size = NUM_THREADS;
        //dynamic memory allocation
        if(threadIdx.x == 0) {
            temp_output_array = (int*)malloc(sizeof(int) * temp_array_size);
            output_array[block_num] = temp_output_array;
        }


        len = len_array[block_num];
        offset = offset_array[block_num];

        //initialize starting values
        SA a = SA();
        prev_value = a;
        temp_prev_val = SA();

        prev_sum = 0;
        temp_prev_sum = 0;
        int loop;

        //If the string is longer than NUM_THREADS
        for(int ph = 0; ph < len; ph += NUM_THREADS) {

            loop = threadIdx.x + ph;
            char c = 0;

            if(loop < len) {
                c = line[loop + offset ];
	            a = d_SA_Table[c];
            }
            __syncthreads();

            BlockScan(temp_storage).ExclusiveScan(a, a, prev_value, SA_op(), temp_prev_val);
            __syncthreads();
           
            start_state = prev_value.v[0];
            int state = a.v[start_state];
            int start = (int) d_E[(int) (NUM_CHARS * state + c)];
            int end;
            BlockScan2(temp_storage2).ExclusiveSum(start, end, temp_prev_sum);
            if(start == 1 && loop < len) {
                (output_array[block_num])[end + prev_sum] = loop;
            }

            if(threadIdx.x == 0) {
            	prev_value = temp_prev_val;
            	prev_sum += temp_prev_sum;
            }

            __syncthreads();

            if(threadIdx.x == 0) {
                if(prev_sum > (NUM_THREADS / 2)) {
                    temp_array_size += NUM_THREADS;
                    int* temp_ptr = (int*)malloc(sizeof(int) * temp_array_size);
                    for(int n = 0; n < prev_sum; n++) {
                        temp_ptr[n] = output_array[block_num][n];
                    }
                    free(output_array[block_num]);
                    output_array[block_num] = temp_ptr;
                }
            }
            __syncthreads();
                    
        }

        if(loop == len - 1) {
        	if(taxi_application)
				prev_sum++;
            num_commas_array[block_num] = prev_sum;
            int temp = atomicAdd(total_num_commas, prev_sum);
        }



        //to get the next line
        if(threadIdx.x == 0) 
            line_num = atomicInc((unsigned int*) index, INT_MAX);
         __syncthreads();
        block_num =  line_num;
    }


}

__global__
void output_sort(int* input, int len, int* output) {
    typedef cub::BlockScan<int, NUM_THREADS> BlockScan; 
    __shared__ typename BlockScan::TempStorage temp_storage;
    __shared__ int prev_sum;

    int temp_prev_sum = 0;
    prev_sum = 0;

    for(int ph = 0; ph < (int)ceilf(((float)(len) / (float)NUM_THREADS)); ph ++) {
    	int loop = threadIdx.x + ph * NUM_THREADS;
    	temp_prev_sum = prev_sum;

	    int start = input[loop];
	    int end;
	    BlockScan(temp_storage).ExclusiveSum(start, end, temp_prev_sum);
	    
	    if(loop < len)
	    	output[loop] = end + prev_sum;
	    __syncthreads();
	    if (threadIdx.x == 0)
	    	prev_sum += temp_prev_sum;
	    __syncthreads();

    }

    __syncthreads();


}




__global__
void polyline_coords (char* buffer, int* len_array, int* offset_array, int* comma_offset_array, int* comma_array,
                    int* output_len_array, int* output_offset_array, int* label_len_array, int* label_offset_array, int total_lines){

        int loop = threadIdx.x + blockIdx.x * blockDim.x;
        if(loop < total_lines) {
            int offset = offset_array[loop];
            int comma_offset = comma_offset_array[loop];
            int len = len_array[loop];

            int start_idx = offset + comma_array[comma_offset + 7] + 3; 
            int end_idx = offset + len - 2;

            output_len_array[loop] = end_idx - start_idx;
            output_offset_array[loop] = start_idx; // -1 for the first index

            int label_start_idx = offset + 1;
            int label_end_idx = offset + comma_array[comma_offset] - 1;
            int label_len = label_end_idx - label_start_idx;

            label_len_array[loop] = label_len;
            label_offset_array[loop] = label_start_idx;


        }
    
}


__global__
void coord_len_offset(  char* buffer, int* len_array, int* offest_array, int* line_idx_array, int* p_array, int* p_offset_array, int* p_comma_offset_array, int total_num, int garbage_char,
                        int* c_len_array, int* label_len_array) {

        int coord_num = threadIdx.x + blockIdx.x * blockDim.x;
        int len;


        if(coord_num < total_num) {
            int line_num = line_idx_array[coord_num];
            int comma_off = p_comma_offset_array[line_num + 1];
            int cur = p_array[coord_num];

            if(coord_num == comma_off - 1){
                len = len_array[line_num] - (p_offset_array[line_num] - offest_array[line_num]) - cur - garbage_char - CSV_FILE;
            }
            else {
                int next = p_array[coord_num + 1];
                len = next - cur - garbage_char;
            }   
           // offset = (int)(buffer + cur + p_offset_array[line_num]);
            int label_len = label_len_array[line_num];
            c_len_array[coord_num] = (len + label_len);
            //printf("%d", len);
            //c_offset_array[coord_num] = offset;

        }


}



__global__
void switch_xy(char* buffer, int* line_idx_array,int* polyline_array, int* p_offset_array, int* c_len_array, int* c_offset_array,
                char* switched_array, int total, int total2, int* label_len_array, int* label_offset_array){

    __shared__ int comma_idx;
    __shared__ int line_num;
    __shared__ int label_len;
    __shared__ int label_offset;



    int block_num = blockIdx.x;
    if(threadIdx.x == 0){
        line_num = line_idx_array[block_num];
        label_len = label_len_array[line_num];
        label_offset = label_offset_array[line_num];
    }
    __syncthreads();

  //  int p_comma_off = p_comma_offset_array[line_num + 1];
    int cur = polyline_array[block_num];

    int len = c_len_array[block_num] - label_len;
    int offset = c_offset_array[block_num];
    long start_idx = cur + p_offset_array[line_num];


    if(threadIdx.x < label_len) {
        switched_array[offset + threadIdx.x] = buffer[threadIdx.x + label_offset];
    }

    else if(threadIdx.x < len + label_len) {

        int coord_idx = threadIdx.x - label_len;

        if(buffer[start_idx + coord_idx] == ',')
            comma_idx = coord_idx;
        __syncthreads();

        int position = coord_idx - comma_idx;

        if((coord_idx == 0) || (coord_idx == len - 1) ){
            switched_array[offset + coord_idx + label_len ] = buffer[start_idx + coord_idx];
        }
        else if(position == 1) {
            switched_array[offset + len - coord_idx + label_len] = buffer[start_idx + coord_idx];
        }
        else if(position == 0){
            switched_array[offset + len - 2 - coord_idx + label_len] = buffer[start_idx + coord_idx];
        }
        else if(position > 0){
            switched_array[offset + position - 1 + label_len] = buffer[start_idx + coord_idx];
        }

        else{
            switched_array[offset + len - 1 - abs(position) + label_len] = buffer[start_idx + coord_idx];
        }

    }
    

}

__global__
void clear_array (int* input_array, int len) {

    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if(idx < len) {
        input_array[idx] = 0;
    }

}


//CPU functions

int     D[NUM_STATES][NUM_CHARS];
uint8_t E[NUM_STATES][NUM_CHARS];
SA 		SA_Table[NUM_CHARS];

void add_transition (int state, uint8_t input, int next_state) 
{
    D[state][input] = next_state;
}

void add_default_transition(int state, int next_state) 
{
    for (int i = 0; i < NUM_CHARS; i++) 
        D[state][i] = next_state;
}

void add_emission(int state, uint8_t input, uint8_t value) 
{
    E[state][input] = value;
}

void add_default_emission(int state, uint8_t value) 
{
    for (int i = 0; i < NUM_CHARS; i++) 
        E[state][i] = value;
}

void SA_generate () {
	for (int i = 0; i < NUM_CHARS; i++) {
		for(int j = 0; j < NUM_STATES; j++) {
			(SA_Table[i]).v[j] = D[j][i];
		}
	}
}


void Dtable_generate() 
{
    for (int i = 0; i < NUM_STATES; i++) 
        add_default_transition(i ,i);
    
    add_default_transition(2 , 1);
   // add_default_transition(3 , 0);

    add_transition(0, '[', 1);
    add_transition(1, '\\', 2);
    add_transition(1, ']', 0);
 //   add_transition(0, '\\', 3);
}

void Etable_generate() 
{
    for(int i = 0; i < NUM_STATES; i++) 
        add_default_emission(i, 0);
    
    add_emission(0, ',', 1);
}

int main() {

    Dtable_generate();
    Etable_generate();
    SA_generate();

    SA* d_SA_Table;
    cudaMalloc((SA**) &d_SA_Table, NUM_CHARS * sizeof(SA));

    uint8_t* d_E;
    cudaMalloc((uint8_t**) &d_E, NUM_STATES * NUM_CHARS * sizeof(uint8_t));

    //cudaMemcpyToSymbol(d_D, D, NUM_STATES * NUM_CHARS * sizeof(int));
    //cudaMemcpyToSymbol(d_E, E, NUM_STATES * NUM_CHARS * sizeof(uint8_t));

    cudaMemcpy(d_E, E, NUM_STATES * NUM_CHARS * sizeof(uint8_t), cudaMemcpyHostToDevice);
    
    cudaMemcpy(d_SA_Table, SA_Table, NUM_CHARS * sizeof(SA), cudaMemcpyHostToDevice);



    std::ifstream is(INPUT_FILE);

    // get length of file:
    is.seekg (0, std::ios::end);
    long length = is.tellg();
    is.seekg (0, std::ios::beg);

    if(length > BUFFER_SIZE){
        cout<<"Error: File is too large to be read to buffer"<<endl;
    }
    else{
        string line; 
        long line_length;
        long line_count = 0; 
        long char_offset = 0; 
        int total_num_commas;

        // allocate memory:
        char* buffer = new char [BUFFER_SIZE];
        int* len_array = new int[NUM_LINES];
        int* offset_array = new int[NUM_LINES];
        int* comma_offset_array = new int[NUM_LINES];
        int* comma_len_array = new int [NUM_LINES];

        offset_array[0] = 0;

        while (getline(is, line)){

            line_length = line.size();

            // keep track of lengths of each line
            len_array[line_count] = line_length;

            // update offset from start of file
            char_offset += line_length + 1;
            offset_array[line_count + 1] = char_offset;

            // increment line index
            line_count++;

        }
        is.close();
        // reopen file stream
        std::ifstream is(INPUT_FILE);

        // read data as a block:
        is.read (buffer,length);

        // close filestream
        is.close();

        //Memory allocation for kernel functions
    
        int** d_output_array;
        cudaMalloc((int**)&d_output_array, line_count * sizeof(int*));

        char* d_buffer;
        cudaMalloc((char**) &d_buffer, BUFFER_SIZE * sizeof(char));

        int* d_len_array;
        cudaMalloc((int**) &d_len_array, line_count * sizeof(int));

        int* d_offset_array;
        cudaMalloc((int**) &d_offset_array, line_count * sizeof(int));

        int* d_num_commas;
        cudaMalloc((int**) &d_num_commas, line_count * sizeof(int));


        int* d_comma_offset_array;
        cudaMalloc((int**) &d_comma_offset_array, line_count * sizeof(int));


        int* d_stack;
        cudaMalloc((int**) &d_stack, sizeof(int));

        int* d_temp_base;
        cudaMalloc((int**) &d_temp_base, sizeof(int));

        int* d_total_num_commas;
        cudaMalloc((int**) &d_total_num_commas, sizeof(int));


        int temp = 0;

        auto t1 = Clock::now();

        cudaMemcpy(d_buffer, buffer, BUFFER_SIZE * sizeof(char), cudaMemcpyHostToDevice);     
        cudaMemcpy(d_len_array, len_array, line_count * sizeof(int), cudaMemcpyHostToDevice);     
        cudaMemcpy(d_offset_array, offset_array, line_count * sizeof(int), cudaMemcpyHostToDevice);    
        cudaMemcpy(d_stack, &temp, sizeof(int), cudaMemcpyHostToDevice);
        cudaMemcpy(d_temp_base, &temp, sizeof(int), cudaMemcpyHostToDevice);
        cudaMemcpy(d_total_num_commas, &temp, sizeof(int), cudaMemcpyHostToDevice);



        auto t2 = Clock::now();

        cout <<"Host to Device:" <<std::chrono::duration_cast<std::chrono::microseconds>(t2 - t1).count() << " microseconds" << endl;

        dim3 dimGrid(NUM_BLOCKS,1,1);
        dim3 dimBlock(NUM_THREADS,1,1);

        auto t3 = Clock::now();

        merge_scan<<<dimGrid, dimBlock>>>(d_buffer, d_len_array, d_offset_array, d_output_array, d_stack, line_count, d_num_commas, d_SA_Table, d_total_num_commas, d_E, 0);

        cudaDeviceSynchronize();


        int* d_comma_offset_array2;
        cudaMalloc((int**)&d_comma_offset_array2, (line_count + 1) * sizeof(int));

        output_sort<<<1, NUM_THREADS>>> (d_num_commas, line_count + 1, d_comma_offset_array2);

        cudaMemcpy(&total_num_commas, d_total_num_commas, sizeof(int), cudaMemcpyDeviceToHost);

        int* d_final_array;
        cudaMalloc((int**) &d_final_array, total_num_commas * sizeof(int));


        int* h_output_array = new int[total_num_commas];

        cudaMemcpy(d_stack, &temp, sizeof(int), cudaMemcpyHostToDevice);

        cudaDeviceSynchronize();

        remove_empty_elements<<<dimGrid, dimBlock>>> (d_output_array, d_num_commas, line_count, d_stack, d_temp_base, d_comma_offset_array2, d_final_array, d_final_array /* temp array */, 0);

        cudaDeviceSynchronize();

        auto t4 = Clock::now();
        cout << "data trans:" << std::chrono::duration_cast<std::chrono::microseconds>(t4 - t3).count() << " microseconds" << endl;


        auto t5 = Clock::now();
        //change the size later
        cudaMemcpy(h_output_array, d_final_array, total_num_commas * sizeof(int), cudaMemcpyDeviceToHost);
        cudaMemcpy(comma_len_array, d_num_commas, line_count * sizeof(int), cudaMemcpyDeviceToHost);
        cudaMemcpy(comma_offset_array, d_comma_offset_array2, (line_count + 1)* sizeof(int), cudaMemcpyDeviceToHost);
        auto t6 = Clock::now();
        cout << "Device to Host:" << std::chrono::duration_cast<std::chrono::microseconds>(t6 - t5).count() << " microseconds" << endl;

        int* label_len_array = new int[line_count];
        int* label_offset_array = new int[line_count];

        int* d_polyline_len_array;
        cudaMalloc((int**) &d_polyline_len_array, line_count * sizeof(int));

        int* d_polyline_offset_array;
        cudaMalloc((int**) &d_polyline_offset_array, line_count * sizeof(int));

	    int* d_label_len_array;
        cudaMalloc((int**) &d_label_len_array, line_count * sizeof(int));

        int* d_label_offset_array;
        cudaMalloc((int**) &d_label_offset_array, line_count * sizeof(int));


        dim3 dimGridPoly(ceil((float)line_count/NUM_THREADS),1,1);

        polyline_coords<<<dimGridPoly, dimBlock>>>(d_buffer, d_len_array, d_offset_array, d_comma_offset_array2, d_final_array, 
                d_polyline_len_array, d_polyline_offset_array, d_label_len_array, d_label_offset_array, line_count);

        cudaDeviceSynchronize();


        cudaMemcpy(label_len_array, d_label_len_array, line_count * sizeof(int), cudaMemcpyDeviceToHost);
		cudaMemcpy(label_offset_array, d_label_offset_array, line_count * sizeof(int), cudaMemcpyDeviceToHost);
        

        cudaMemcpy(d_stack, &temp, sizeof(int), cudaMemcpyHostToDevice);
        cudaMemcpy(d_temp_base, &temp, sizeof(int), cudaMemcpyHostToDevice);
        cudaMemcpy(d_total_num_commas, &temp, sizeof(int), cudaMemcpyHostToDevice);


        int* d_polyline_num_commas;
        cudaMalloc((int**) &d_polyline_num_commas, line_count * sizeof(int));

        merge_scan<<<dimGrid, dimBlock>>>(d_buffer, d_polyline_len_array, d_polyline_offset_array, d_output_array, d_stack, line_count, d_polyline_num_commas, d_SA_Table, d_total_num_commas, d_E, 1);

        cudaDeviceSynchronize();


        int* d_polyline_comma_offset_array2;
        cudaMalloc((int**) &d_polyline_comma_offset_array2, sizeof(int) * (line_count + 1));


        output_sort<<<1, NUM_THREADS>>> (d_polyline_num_commas, line_count + 1, d_polyline_comma_offset_array2);


        int polyline_total_num_commas;
        cudaMemcpy(&polyline_total_num_commas, d_total_num_commas, sizeof(int), cudaMemcpyDeviceToHost);

        int* d_polyline_array;
        cudaMalloc((int**) &d_polyline_array, polyline_total_num_commas * sizeof(int));

        int* p_output_array = new int[polyline_total_num_commas];

        cudaMemcpy(d_stack, &temp, sizeof(int), cudaMemcpyHostToDevice);

        cudaDeviceSynchronize();

        int* d_polyline_comma_offset_array;
        cudaMalloc((int**) &d_polyline_comma_offset_array, sizeof(int) * line_count);


        int* d_line_num_array;
        cudaMalloc((int**) &d_line_num_array, sizeof(int) * polyline_total_num_commas);


        remove_empty_elements<<<dimGrid, dimBlock>>> (d_output_array, d_polyline_num_commas, line_count, d_stack, d_temp_base, d_polyline_comma_offset_array2, d_polyline_array, d_line_num_array, 1);

        cudaDeviceSynchronize();

        int* polyline_array = new int[polyline_total_num_commas];
        int* polyline_offset_array = new int[line_count];
        int* polyline_comma_len_array = new int [line_count];
        int* line_idx_array = new int[polyline_total_num_commas];
        int* polyline_comma_offset_array = new int[line_count + 1];


        cudaMemcpy(polyline_array, d_polyline_array, sizeof(int) * polyline_total_num_commas, cudaMemcpyDeviceToHost);
        cudaMemcpy(polyline_comma_len_array, d_polyline_num_commas, sizeof(int) * line_count, cudaMemcpyDeviceToHost);
        cudaMemcpy(polyline_comma_offset_array, d_polyline_comma_offset_array2, sizeof(int) * (line_count + 1), cudaMemcpyDeviceToHost);


        cudaMemcpy(polyline_offset_array, d_polyline_offset_array, sizeof(int) * (line_count), cudaMemcpyDeviceToHost);

        cudaMemcpy(line_idx_array, d_line_num_array, sizeof(int) * polyline_total_num_commas, cudaMemcpyDeviceToHost);

        //switch_xy setup

        int* c_len_array = new int[polyline_total_num_commas];
        int* c_offset_array = new int[polyline_total_num_commas + 1];


        int* d_c_len_array;
        cudaMalloc((int**) &d_c_len_array, polyline_total_num_commas * sizeof(int));
        int* d_c_offset_array;
        cudaMalloc((int**) &d_c_offset_array, (polyline_total_num_commas + 1) * sizeof(int));

        dim3 dimGridcoord(ceil((float)polyline_total_num_commas / NUM_THREADS), 1, 1);
        dim3 dimBlockcoord(NUM_THREADS, 1, 1);
        coord_len_offset<<<dimGridcoord, dimBlockcoord>>>(d_buffer, d_len_array, d_offset_array, d_line_num_array, d_polyline_array, d_polyline_offset_array, d_polyline_comma_offset_array2, polyline_total_num_commas, 
                                                          2, d_c_len_array, d_label_len_array);
        cudaDeviceSynchronize();
        cudaMemcpy(c_len_array, d_c_len_array, polyline_total_num_commas * sizeof(int), cudaMemcpyDeviceToHost);
        
        output_sort<<<1, NUM_THREADS>>>(d_c_len_array, polyline_total_num_commas + 1 ,d_c_offset_array);
        cudaMemcpy(c_offset_array, d_c_offset_array, (polyline_total_num_commas + 1) * sizeof(int), cudaMemcpyDeviceToHost);

        int coord_size;
        cudaMemcpy(&coord_size, (int*) (d_c_offset_array + polyline_total_num_commas), sizeof(int), cudaMemcpyDeviceToHost);

        char* switched_array = new char[coord_size];

        char* d_switched_array;
        cudaMalloc((int**) &d_switched_array, coord_size * sizeof(char));


        dim3 coordGrid(polyline_total_num_commas,1,1);
        dim3 coordBlock(128,1,1);

        switch_xy<<<coordGrid,coordBlock>>>(d_buffer, d_line_num_array, d_polyline_array, d_polyline_offset_array, d_c_len_array, d_c_offset_array,
                                            d_switched_array, coord_size, polyline_total_num_commas, d_label_len_array, d_label_offset_array);

        cudaDeviceSynchronize();

        cudaMemcpy(switched_array, d_switched_array, coord_size * sizeof(char), cudaMemcpyDeviceToHost);     


         for(int i = 0; i < polyline_total_num_commas; i++) {
            int c_len = c_len_array[i];
            int c_off = c_offset_array[i];

            for(int j =0; j < c_len; j++){
                printf("%c",switched_array[c_off + j]);
            }
            cout << endl;
          }

        // for(int i = 0; i < line_count; i ++) {
        //     printf("%d\n", label_len_array[i]);
        // }

        // for(int i = 0; i < line_count; i++) {
        //     int co_len = comma_len_array[i];
        //     int co_off = comma_offset_array[i];
        //     for(int j = 0; j < co_len; j++){
        //         printf("%d ", h_output_array[co_off + j]);
        //     }
        //     cout << endl;
        // }
       



	    cudaFree(d_polyline_array);
        cudaFree(d_polyline_len_array);
        cudaFree(d_polyline_offset_array);
        cudaFree(d_output_array);
        cudaFree(d_buffer);
        cudaFree(d_len_array);
        cudaFree(d_offset_array);
        cudaFree(d_comma_offset_array);
        cudaFree(d_comma_offset_array2);

        cudaFree(d_stack);
        cudaFree(d_temp_base);
        cudaFree(d_num_commas);

        cudaFree(d_line_num_array);
        cudaFree(d_switched_array);
        cudaFree(d_c_len_array);
        cudaFree(d_c_offset_array);

        cudaFree(d_label_len_array);
        cudaFree(d_label_offset_array);



        // delete temporary buffers
        delete [] buffer;
        delete [] len_array;
        delete [] offset_array;
        delete [] comma_offset_array;
        delete [] comma_len_array;
        delete [] h_output_array;

        delete [] line_idx_array;
        delete [] switched_array;
        delete [] c_len_array;
        delete [] c_offset_array;

        delete [] label_len_array;
        delete [] label_offset_array;

    }



    return 0;
}


