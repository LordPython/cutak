# Cutak

### A Bot to Play Tak

Cutak is a bot written in C++ to play tak (see http://cheapass.com/node/215 and https://www.kickstarter.com/projects/cheapassgames/tak-a-beautiful-game?ref=nav_search) 
on the https://playtak.com website.

It currently does a pretty standard negamax search, looking ahead 5-6 plies, 
And has a relatively simple evaluation function.

The libtak subdirectory contains the general framework used to simulate games of tak.

### External Dependencies

The only dependency is on asio, used to do the networking, which is included as a git submodule, so make sure to clone with --recursive

### About the name

I'm planning on experimenting with GPU acceleration using CUDA in the future, hence the name *cu*tak.
