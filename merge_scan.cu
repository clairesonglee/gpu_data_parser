
#include <cstdint>
#include <iostream>
#include <fstream>
#include <string>
#include <chrono>
#include <cub/cub.cuh>

#include <stdio.h> 

using namespace std;

#define NUM_STATES 4
#define NUM_CHARS  256
#define NUM_THREADS 128
#define NUM_LINES 100
#define NUM_BLOCKS 30

#define BUFFER_SIZE 2500
#define NUM_COMMAS 10 
#define INPUT_FILE "./input_file.txt"

typedef std::chrono::high_resolution_clock Clock;

//Transition table for GPU function
__constant__ int     d_D[NUM_STATES * NUM_CHARS];
//Emission table for GPU function
__constant__ uint8_t d_E[NUM_STATES * NUM_CHARS];




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

//a = b
__device__ void SA_copy(SA & a, SA &b) {
    for(int i = 0; i < NUM_STATES; i ++) 
        a.v[i] = b.v[i];
}

struct SA_op {
    __device__ SA operator()(SA &a, SA &b){
        SA c;
        for(int i = 0; i < NUM_STATES; i ++) 
            c.v[i] = b.v[a.v[i]];
        
        return c;
    }
};

 //no array_len
//offest_ptr_array
__global__
void merge_scan (char* line, int* len_array, int* offset_array, int* output_array, int* index, int total_lines){


    typedef cub::BlockScan<SA, NUM_THREADS> BlockScan;
    typedef cub::BlockScan<int, NUM_THREADS> BlockScan2;

    __shared__ typename BlockScan::TempStorage temp_storage;
    __shared__ typename BlockScan2::TempStorage temp_storage2;
    __shared__ SA prev_value;
    __shared__ int prev_sum;
    __shared__ int line_num;

    int len, offset;
    int block_num;

    if(threadIdx.x == 0) 
        line_num = atomicInc((unsigned int*) &index[0], INT_MAX);
    __syncthreads();
    block_num =  line_num;

    while(block_num < total_lines) {
        len = len_array[block_num];
        offset = offset_array[block_num];

        //initialize starting values
        SA a = SA();
        SA_copy(prev_value , a);

        prev_sum = 0;

        //If the string is longer than NUM_THREADS
        for(int loop = threadIdx.x; loop < len; loop += NUM_THREADS) {
            if(loop < len) {
                char c = line[loop + offset];

                //Check that it has to fetch the data from the previous loop
                if(loop % NUM_THREADS == 0) {
                    SA_copy(a, prev_value);
                }

                else {   
                    for(int i = 0; i < NUM_STATES; i++){
                        int x = d_D[(int)(i* NUM_CHARS + c)];
                        a.set_SA(i, x);
                    }
                }

                BlockScan(temp_storage).InclusiveScan(a, a, SA_op());
                __syncthreads();

                int state = a.v[0];
                int start = (int) d_E[(int) (NUM_CHARS * state + c)];
                int end;
                BlockScan2(temp_storage2).InclusiveSum(start, end);
                if(start == 1) 
                    output_array[end - 1 + block_num * NUM_COMMAS + prev_sum] = loop;

                //save the values for the next loop
                if((loop + 1) % NUM_THREADS == 0) {
                    SA_copy(prev_value , a);
                    prev_sum = end;
                }   
            }
            __syncthreads();

        }
        if(threadIdx.x == 0) 
            line_num = atomicInc((unsigned int*) &index[0], INT_MAX);
         __syncthreads();
        block_num =  line_num;
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

void Dtable_generate() 
{
    for (int i = 0; i < NUM_STATES; i++) 
        add_default_transition(i ,i);
    
    add_default_transition(2 , 1);
    add_default_transition(3 , 0);

    add_transition(0, '[', 1);
    add_transition(1, '\\', 2);
    add_transition(1, ']', 0);
    add_transition(0, '\\', 3);
}

void Etable_generate() 
{
    for(int i = 0; i < NUM_STATES; i++) 
        add_default_emission(i, 0);
    
    add_emission(0, ',', 1);
}

int max_length()
{
    std::ifstream is(INPUT_FILE);   // open file
    string line;
    int length = 0; 

    while (getline(is, line)){
        if(length < line.length())
            length = line.length();
    }
    is.close();
    
    return length; 
}



int main() {

    Dtable_generate();
    Etable_generate();

    cudaMemcpyToSymbol(d_D, D, NUM_STATES * NUM_CHARS * sizeof(int));
    cudaMemcpyToSymbol(d_E, E, NUM_STATES * NUM_CHARS * sizeof(uint8_t));

    int* h_output_array = new int[BUFFER_SIZE];

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

        // allocate memory:
        char* buffer = new char [BUFFER_SIZE];
        int* len_array = new int[NUM_LINES];
        int* offset_array = new int[NUM_LINES];

        offset_array[0] = 0;

        while (getline(is, line)){

            line_length = line.size();
            //cout<<"line "<<line<<endl;

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
        //cout<<"buffer "<<buffer<<endl;

        //Memory allocation for kernel functions
    
        int* d_output_array;
        cudaMalloc((int**)&d_output_array, BUFFER_SIZE * sizeof(int));

        char* d_buffer;
        cudaMalloc((char**) &d_buffer, BUFFER_SIZE * sizeof(char));

        int* d_len_array;
        cudaMalloc((int**) &d_len_array, line_count * sizeof(int));

        int* d_offset_array;
        cudaMalloc((int**) &d_offset_array, line_count * sizeof(int));

        int* d_num_commas;
        cudaMalloc((int**) &d_num_commas, sizeof(int));

        int temp = 0;
        cudaMemcpy(d_buffer, buffer, BUFFER_SIZE * sizeof(char), cudaMemcpyHostToDevice);     
        cudaMemcpy(d_len_array, len_array, line_count * sizeof(int), cudaMemcpyHostToDevice);     
        cudaMemcpy(d_offset_array, offset_array, line_count * sizeof(int), cudaMemcpyHostToDevice);    
        cudaMemcpy(d_num_commas, &temp, sizeof(int), cudaMemcpyHostToDevice);

        dim3 dimGrid(NUM_BLOCKS,1,1);
        dim3 dimBlock(NUM_THREADS,1,1);

        merge_scan<<<dimGrid, dimBlock>>>(d_buffer, d_len_array, d_offset_array, d_output_array, d_num_commas,line_count);


        cudaMemcpy(h_output_array, d_output_array, BUFFER_SIZE * sizeof(int), cudaMemcpyDeviceToHost);

         for(int i = 0; i < line_count; i++) {
            for(int j = 0; j < NUM_COMMAS; j++) {
                if(h_output_array[i * NUM_COMMAS +  j] != 0)
                    cout << h_output_array[i * NUM_COMMAS +  j] << " "; 
            }
            cout << endl;
         }  
        

        //clear_array<<<dimGrid, dimBlock>>>(d_output_array, BUFFER_SIZE);

        // close filestream
        is.close();


        cudaFree(d_output_array);
        cudaFree(d_buffer);
        cudaFree(d_len_array);
        cudaFree(d_offset_array);
        cudaFree(d_num_commas);

        // delete temporary buffers
        delete [] buffer;
        delete [] len_array;
        delete [] offset_array;
    }
    delete [] h_output_array;



    return 0;
}


