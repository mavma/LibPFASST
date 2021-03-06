#  Compilers for gnu Linux
FC = mpifort
CC = mpicc

AR=ar rcs

FFLAGS = -Ibuild -Jinclude -cpp -ffree-line-length-none

ifeq ($(DEBUG),TRUE)
FFLAGS += -fcheck=all -fbacktrace -g -ffpe-trap=invalid,zero,overflow -fbounds-check -fimplicit-none -ffree-line-length-none
else
FFLAGS += -O3 
endif