!
! Copyright (c) 2012, Matthew Emmett and Michael Minion.  All rights reserved.
!

module hooks
  use pf_mod_dtype
  use pf_mod_ndarray
  implicit none

  interface
     subroutine dump_mkdir(dname, dlen) bind(c)
       use iso_c_binding
       character(c_char), intent(in) :: dname
       integer(c_int),    intent(in), value :: dlen
     end subroutine dump_mkdir

     subroutine dump_numpy(dname, fname, endian, dim, shape, nvars, array) bind(c)
       use iso_c_binding
       character(c_char), intent(in) :: dname, fname, endian(4)
       integer(c_int),    intent(in), value :: dim, nvars
       integer(c_int),    intent(in) :: shape(dim)
       real(c_double),    intent(in) :: array(nvars)
     end subroutine dump_numpy
  end interface

contains

  subroutine echo_error_hook(pf, level, state, levelctx)
    use solutions, only: exact
    type(pf_pfasst_t),   intent(inout) :: pf
    type(pf_level_t),    intent(inout) :: level
    type(pf_state_t),    intent(in)    :: state
    type(c_ptr),         intent(in)    :: levelctx

    real(c_double) :: yexact(level%nvars)
    real(pfdp), pointer :: qend(:)

    qend => array1(level%qend)

    call exact(state%t0+state%dt, level%nvars, yexact)
    print '("error: step: ",i3.3," iter: ",i4.3," error: ",es14.7)', &
         state%step+1, state%iter, maxval(abs(qend-yexact))

  end subroutine echo_error_hook


  subroutine dump_hook(pf, level, state, levelctx)
    use probin, only: output
    type(pf_pfasst_t),   intent(inout) :: pf
    type(pf_level_t),    intent(inout) :: level
    type(pf_state_t),    intent(in)    :: state
    type(c_ptr),         intent(in)    :: levelctx

    character(len=256)     :: fname
    type(ndarray), pointer :: qend

    call c_f_pointer(level%qend, qend)

    write(fname, "('s',i0.5,'i',i0.3,'l',i0.2,'.npy')") &
         state%step, state%iter, level%level

    call dump_numpy(trim(output)//c_null_char, trim(fname)//c_null_char, '<f8'//c_null_char, &
         qend%dim, qend%shape, size(qend%flatarray), qend%flatarray)

  end subroutine dump_hook


  subroutine echo_residual_hook(pf, level, state, levelctx)
    use iso_c_binding
    use pf_mod_utils
    type(pf_pfasst_t), intent(inout) :: pf
    type(pf_level_t),  intent(inout) :: level
    type(pf_state_t),  intent(in)    :: state
    type(c_ptr),       intent(in)    :: levelctx

    real(pfdp), pointer :: r(:)

    r => array1(level%R(level%nnodes-1))

    print '("resid: step: ",i3.3," iter: ",i4.3," level: ",i2.2," resid: ",es14.7)', &
         state%step+1, state%iter, level%level, maxval(abs(r))
  end subroutine echo_residual_hook

end module hooks
