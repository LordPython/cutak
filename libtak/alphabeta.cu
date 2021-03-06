#include "tak/tak.hpp"
#include "tak/ptn.hpp"
#include "tak/tps.hpp"
#include "cub/cub.cuh"
#include <chrono>

struct Eval {
  using Score = int32_t;

  enum S : Score {
    MIN = -(1<<30),
    MAX = (1<<30),
    LOSS = -(1<<29),
    WIN = 1<<29,
  };

  // Evaluates the strength of one player
  template<uint8_t SIZE>
  CUDA_CALLABLE static Score eval_player(const Board<SIZE>& state, uint8_t player) {
    int top_flats = 0;
    int adj_flats = 0;
    int flats = 0;
    int caps = 0;
    int influence = 0;
    int captured = 0;
    int captured_penalty = 0;
    for(int i = 0; i < SIZE*SIZE; i++) {
      Stack s = state.board[i];
      int cap_this_stack = 0;
      if(s.height && s.top == Piece::FLAT && s.owner() == player) {
        top_flats++;
        uint8_t o = i+Move<SIZE>::Dir::NORTH;
        if(o < SIZE*SIZE && state.board[o].height && state.board[o].owner() == player && state.board[o].top == Piece::FLAT) {
          adj_flats++;
        }
        o = i+Move<SIZE>::Dir::SOUTH;
        if(o < SIZE*SIZE && state.board[o].height && state.board[o].owner() == player && state.board[o].top == Piece::FLAT) {
          adj_flats++;
        }
        o = i+Move<SIZE>::Dir::EAST;
        if(o/SIZE == i/SIZE && state.board[o].height && state.board[o].owner() == player && state.board[o].top == Piece::FLAT) {
          adj_flats++;
        }
        o = i+Move<SIZE>::Dir::WEST;
        if(o/SIZE == i/SIZE && state.board[o].height && state.board[o].owner() == player && state.board[o].top == Piece::FLAT) {
          adj_flats++;
        }
        //influence += (0x7F&map.left[i]) + (0x7F&map.right[i]) + (0x7F&map.up[i]) + (0x7F&map.down[i]);
        uint64_t owners = state.board[i].owners;
        for(int i = 1; i < state.board[i].height; i++) {
          owners >>= 1;
          if((owners&1) == player) {
            flats += 1;
          } else {
            captured += 1;
            cap_this_stack += 1;
          }
        }
        if(cap_this_stack >= 3) {
          captured_penalty += cap_this_stack*cap_this_stack;
        }
      } else if(s.height && s.top == Piece::CAP && s.owner() == player) {
        caps++;
      }

      int adj_ally = 0;
      int adj_enemy = 0;
      uint8_t o = i+Move<SIZE>::Dir::NORTH;
      if(o < SIZE*SIZE && state.board[o].height) {
        if(state.board[o].owner() == player) {
          adj_ally++;
        } else {
          adj_enemy++;
        }
      }
      o = i+Move<SIZE>::Dir::SOUTH;
      if(o < SIZE*SIZE && state.board[o].height) {
        if(state.board[o].owner() == player) {
          adj_ally++;
        } else {
          adj_enemy++;
        }
      }
      o = i+Move<SIZE>::Dir::EAST;
      if(o/SIZE == i/SIZE && state.board[o].height) {
        if(state.board[o].owner() == player) {
          adj_ally++;
        } else {
          adj_enemy++;
        }
      }
      o = i+Move<SIZE>::Dir::WEST;
      if(o/SIZE == i/SIZE && state.board[o].height) {
        if(state.board[o].owner() == player) {
          adj_ally++;
        } else {
          adj_enemy++;
        }
      }

      influence += adj_ally-adj_enemy;
    }

    return influence*25 + (top_flats/*+adj_flats/2*/)*400 + flats*100 + caps*50 - captured_penalty*100;
  }

  template<uint8_t SIZE>
  CUDA_CALLABLE static Score eval(const Board<SIZE>& state, uint8_t player) {
    return eval_player(state, player) - eval_player(state, !player);
  }
};

const int BLOCK_SIZE = 128;
const int NUM_BLOCKS = 128;

template<uint8_t SIZE>
__global__ void eval_parallel(uint8_t player, int num_moves, Board<SIZE>* board, Move<SIZE>* moves, int* score) {
  //int this_score = Eval::MIN;
  for(int idx = blockIdx.x*blockDim.x + threadIdx.x; idx < num_moves; idx += gridDim.x*blockDim.x) {
    Board<SIZE> b = *board;
    b.execute(moves[idx]);
    //this_score = max(this_score, Eval::eval(b, player));
    score[idx] = Eval::eval(b,player);
  }

  //int max_score = cub::BlockReduce<int, BLOCK_SIZE>().Reduce(this_score, cub::Max());

  // Only one thread in the block needs to write output
  //if(threadIdx.x == 0) {
    //*score = max_score;
  //}
}

template<uint8_t SIZE>
__global__ void eval_more_parallel(uint8_t p, int num_moves, Board<SIZE>* board, Move<SIZE>* moves, int* score) {
  __shared__ Board<SIZE> b;
  for(int idx = (blockDim.x*blockIdx.x + threadIdx.x)/32; idx < num_moves; idx+=gridDim.x*blockDim.x/32) {

    if(threadIdx.x%32 == 0) {
      b = *board;
      b.execute(moves[idx]);
    }

    auto evalx = [&b](uint8_t player) -> int {
      int top_flats = 0;
      int adj_flats = 0;
      int flats = 0;
      int caps = 0;
      int influence = 0;
      int captured = 0;
      int captured_penalty = 0;

      for(int i = threadIdx.x%32; i < SIZE*SIZE; i += 32) {
        Stack s = b.board[i];
        int cap_this_stack = 0;
        if(s.height && s.top == Piece::FLAT && s.owner() == player) {
          top_flats++;
          uint8_t o = i+Move<SIZE>::Dir::NORTH;
          if(o < SIZE*SIZE && b.board[o].height && b.board[o].owner() == player && b.board[o].top == Piece::FLAT) {
            adj_flats++;
          }
          o = i+Move<SIZE>::Dir::SOUTH;
          if(o < SIZE*SIZE && b.board[o].height && b.board[o].owner() == player && b.board[o].top == Piece::FLAT) {
            adj_flats++;
          }
          o = i+Move<SIZE>::Dir::EAST;
          if(o/SIZE == i/SIZE && b.board[o].height && b.board[o].owner() == player && b.board[o].top == Piece::FLAT) {
            adj_flats++;
          }
          o = i+Move<SIZE>::Dir::WEST;
          if(o/SIZE == i/SIZE && b.board[o].height && b.board[o].owner() == player && b.board[o].top == Piece::FLAT) {
            adj_flats++;
          }
          //influence += (0x7F&map.left[i]) + (0x7F&map.right[i]) + (0x7F&map.up[i]) + (0x7F&map.down[i]);
          uint64_t owners = b.board[i].owners;
          for(int i = 1; i < b.board[i].height; i++) {
            owners >>= 1;
            if((owners&1) == player) {
              flats += 1;
            } else {
              captured += 1;
              cap_this_stack += 1;
            }
          }
          if(cap_this_stack >= 3) {
            captured_penalty += cap_this_stack*cap_this_stack;
          }
        } else if(s.height && s.top == Piece::CAP && s.owner() == player) {
          caps++;
        }

        int adj_ally = 0;
        int adj_enemy = 0;
        uint8_t o = i+Move<SIZE>::Dir::NORTH;
        if(o < SIZE*SIZE && b.board[o].height) {
          if(b.board[o].owner() == player) {
            adj_ally++;
          } else {
            adj_enemy++;
          }
        }
        o = i+Move<SIZE>::Dir::SOUTH;
        if(o < SIZE*SIZE && b.board[o].height) {
          if(b.board[o].owner() == player) {
            adj_ally++;
          } else {
            adj_enemy++;
          }
        }
        o = i+Move<SIZE>::Dir::EAST;
        if(o/SIZE == i/SIZE && b.board[o].height) {
          if(b.board[o].owner() == player) {
            adj_ally++;
          } else {
            adj_enemy++;
          }
        }
        o = i+Move<SIZE>::Dir::WEST;
        if(o/SIZE == i/SIZE && b.board[o].height) {
          if(b.board[o].owner() == player) {
            adj_ally++;
          } else {
            adj_enemy++;
          }
        }

        influence += adj_ally-adj_enemy;
      }

      //int s = influence*25 + (top_flats/*+adj_flats/2*/)*400 + flats*100 + caps*50 - captured_penalty*100;
      return influence*25 + (top_flats/*+adj_flats/2*/)*400 + flats*100 + caps*50 - captured_penalty*100;
    };

    int s = evalx(p)-evalx(!p);
    //for (int offset = warpSize/2; offset > 0; offset /= 2) 
      //s += __shfl_down(s, offset);
    s += __shfl_down(s, 16);
    s += __shfl_down(s, 8);
    s += __shfl_down(s, 4);
    s += __shfl_down(s, 2);
    s += __shfl_down(s, 1);

    // Only output one score per warp
    if((threadIdx.x%32) == 0) {
      score[idx] = s;
    }
  }
}


//Macro for checking cuda errors following a cuda launch or api call
#define cudaCheckError() { \
cudaError_t e=cudaGetLastError(); \
  if(e!=cudaSuccess) { \
    printf("Cuda failure %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(e)); \
    exit(0); \
  } \
}

int main() {
  using namespace std::chrono;

  Board<5> host_board;

  // Read in board from tps
  std::string board_tps;
  std::getline(std::cin, board_tps);
  tps::from_str(board_tps, host_board);
  std::cout << tps::to_str(host_board) << std::endl;

  std::vector<Move<5>> host_moves;
  std::vector<Move<5>> moves;

  typename Board<5>::Map map(host_board);
  host_board.forEachMove(map, [&moves] __host__ __device__ (Move<5> m) {
    moves.push_back(m);
    return CONTINUE;
  });

  std::cout << "Num moves: " << moves.size() << std::endl;
  //for(int n = 50; n < 150; n+=5) {
  for(int n = 10; n < 1001; n+=10) {
  //for(int n = 1; n < 2; n++) {
    host_moves.clear();
    for(int i = 0; i < n; i++) {
      host_moves.insert(host_moves.end(), moves.begin(), moves.end());
    }

    int* host_score = new int[host_moves.size()];
    int* host_score2 = new int[host_moves.size()];

    Board<5>* dev_board;
    Move<5>* dev_moves;
    int* dev_score;

    std::cout << "Num moves: " << host_moves.size() << std::endl;


    cudaMalloc(&dev_board, sizeof(host_board));
    cudaMalloc(&dev_moves, host_moves.size()*sizeof(host_moves[0]));
    cudaMalloc(&dev_score, host_moves.size()*sizeof(host_score[0]));
    cudaCheckError();

    auto start = steady_clock::now();
    cudaMemcpy(dev_board, &host_board, sizeof(host_board), cudaMemcpyHostToDevice);
    cudaMemcpy(dev_moves, host_moves.data(), host_moves.size()*sizeof(host_moves[0]), cudaMemcpyHostToDevice);
    cudaCheckError();

    eval_parallel<<<NUM_BLOCKS,BLOCK_SIZE>>>(WHITE, host_moves.size(), dev_board, dev_moves, dev_score);
    cudaMemcpy(host_score, dev_score, host_moves.size()*sizeof(host_score[0]), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    cudaCheckError();
    auto end = steady_clock::now();

    printf("parallel: %d, time: %lu\n", host_score[0], duration_cast<microseconds>(end-start).count());

    start = steady_clock::now();
    cudaMemcpy(dev_board, &host_board, sizeof(host_board), cudaMemcpyHostToDevice);
    cudaMemcpy(dev_moves, host_moves.data(), host_moves.size()*sizeof(host_moves[0]), cudaMemcpyHostToDevice);
    cudaCheckError();

    eval_more_parallel<<<NUM_BLOCKS,BLOCK_SIZE>>>(WHITE, host_moves.size(), dev_board, dev_moves, dev_score);
    cudaMemcpy(host_score2, dev_score, host_moves.size()*sizeof(host_score[0]), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    cudaCheckError();
    end = steady_clock::now();

    printf("more parallel: %d, time: %lu\n", host_score2[0], duration_cast<microseconds>(end-start).count());

    for(int i = 0; i < host_moves.size(); i++) {
      if(host_score[i] != host_score2[i]) {
        //printf("Score %d not the same: %d != %d\n", i, host_score[i], host_score2[i]);
        //return -1;
      }
    }

    start = steady_clock::now();
    int i = 0;
    for(Move<5> move : host_moves) {
      Board<5> b = host_board;
      b.execute(move);
      host_score[i++] = Eval::eval(b,WHITE);
    }
    end = steady_clock::now();
    printf("sequential: %d, time: %lu\n", host_score[0], duration_cast<microseconds>(end-start).count());
  }
}
