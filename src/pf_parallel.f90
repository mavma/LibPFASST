!
! Copyright (C) 2012, 2013 Matthew Emmett and Michael Minion.
!
! This file is part of LIBPFASST.
!
! LIBPFASST is free software: you can redistribute it and/or modify it
! under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! LIBPFASST is distributed in the hope that it will be useful, but
! WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
! General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with LIBPFASST.  If not, see <http://www.gnu.org/licenses/>.
!

! Parallel PFASST routines.

module pf_mod_parallel
  use pf_mod_dtype
  use pf_mod_interpolate
  use pf_mod_restrict
  use pf_mod_utils
  use pf_mod_timer
  use pf_mod_hooks
  implicit none
contains

  !
  ! Build cycle (list of PFASST operations).
  !
  subroutine pf_cycle_build(pf)
    type(pf_pfasst_t), intent(inout) :: pf

    integer :: n, l, c
    integer, pointer :: stages(:)

    select case(pf%ctype)
    case (SDC_CYCLE_V)
       print *, 'V CYCLE'
    case (SDC_CYCLE_FULL)
       print *, 'FULL MG CYCLE'
    case (SDC_CYCLE_OLD)
       print *, 'OLD PFASST CYCLE'

       c = 1
       n = 2*pf%nlevels - 1
       allocate(stages(n))

       do l = pf%nlevels, 2, -1
          stages(c) = SDC_CYCLE_DOWN; c = c + 1
       end do

       stages(c) = SDC_CYCLE_BOTTOM; c = c + 1

       do l = 2, pf%nlevels
          stages(c) = SDC_CYCLE_UP; c = c + 1
       end do
    end select
  end subroutine pf_cycle_build


  !
  ! Predictor.
  !
  subroutine pf_predictor(pf, t0, dt)
    type(pf_pfasst_t), intent(inout) :: pf
    real(pfdp),        intent(in)    :: t0, dt

    type(pf_level_t), pointer :: F, G
    integer :: j, k, l

    call start_timer(pf, TPREDICTOR)

    F => pf%levels(pf%nlevels)
    call spreadq0(F, t0)

    do l = pf%nlevels, 2, -1
       F => pf%levels(l); G => pf%levels(l-1)
       call restrict_time_space_fas(pf, t0, dt, F, G)
       call save(G)
       call G%encap%pack(G%q0, G%Q(1))
    end do

    if (pf%comm%nproc > 1) then

       G => pf%levels(1)
       do k = 1, pf%rank + 1
          pf%state%iter = -k

          ! get new initial value (skip on first iteration)
          if (k > 1) &
               call G%encap%pack(G%q0, G%Q(G%nnodes))

          do j = 1, G%nsweeps
             call G%sweeper%sweep(pf, G, t0, dt)
          end do
          call call_hooks(pf, G%level, PF_POST_SWEEP)
       end do

       ! interpolate: XXX
       do l = 1, pf%nlevels - 1
          F => pf%levels(l+1)
          G => pf%levels(l)
          call interpolate_time_space(pf, t0, dt, F, G,G%Finterp)
          call G%encap%pack(F%q0, F%Q(1))
       end do

    end if

    pf%state%iter  = -1
    pf%state%cycle = -1
    call end_timer(pf, TPREDICTOR)
    call call_hooks(pf, -1, PF_POST_PREDICTOR)

  end subroutine pf_predictor


  !
  ! Run in parallel using PFASST.
  !
  subroutine pf_pfasst_run(pf, q0, dt, tend, nsteps, qend)
    type(pf_pfasst_t), intent(inout) :: pf
    type(c_ptr),       intent(in)    :: q0
    real(pfdp),        intent(in)    :: dt, tend
    type(c_ptr),       intent(in), optional :: qend
    integer,           intent(in), optional :: nsteps

    real(pfdp) :: t0
    integer    :: nblock, b, k, j, l
    type(pf_level_t), pointer :: F, G

    call start_timer(pf, TTOTAL)

    !
    ! initialize
    !

    pf%state%t0   = 0.0d0
    pf%state%dt   = dt
    pf%state%iter = -1

    call pf_cycle_build(pf)

    F => pf%levels(pf%nlevels)
    call F%encap%pack(F%q0, q0)

    if(present(nsteps)) then
       pf%state%nsteps = nsteps
    else
       pf%state%nsteps = ceiling(1.0*tend/dt)
    end if

    nblock = pf%state%nsteps/pf%comm%nproc


    !
    ! time "block" loop
    !

    do b = 1, nblock
       pf%state%block = b
       pf%state%step  = pf%rank + (b-1)*pf%comm%nproc
       pf%state%t0    = pf%state%step * dt
       pf%state%iter  = -1
       pf%state%cycle = -1

       t0 = pf%state%t0

       call call_hooks(pf, -1, PF_PRE_BLOCK)

       call pf_predictor(pf, t0, dt)

       !!!! pfasst iterations (v-cycle)
       do k = 1, pf%niters
          pf%state%iter  = k
          pf%state%cycle = 1

          call start_timer(pf, TITERATION)

          do l = 1, pf%nlevels
             F => pf%levels(l)
             call call_hooks(pf, F%level, PF_PRE_ITERATION)
          end do

          ! post receive requests
          do l = 2, pf%nlevels
             F => pf%levels(l)
             call pf%comm%post(pf, F, F%level*100+k)
          end do

          !! go down the v-cycle
          do l = pf%nlevels, 2, -1
             pf%state%cycle = pf%state%cycle + 1
             F => pf%levels(l)
             G => pf%levels(l-1)

             do j = 1, F%nsweeps
                call F%sweeper%sweep(pf, F, t0, dt)
             end do
             call call_hooks(pf, F%level, PF_POST_SWEEP)
             call pf%comm%send(pf, F, F%level*100+k, .false.)

             call restrict_time_space_fas(pf, t0, dt, F, G)
             call save(G)
          end do

          !! bottom
          pf%state%cycle = pf%state%cycle + 1
          F => pf%levels(1)

          call pf%comm%recv(pf, F, F%level*100+k, .true.)
          do j = 1, F%nsweeps
             call F%sweeper%sweep(pf, F, t0, dt)
          end do
          call call_hooks(pf, F%level, PF_POST_SWEEP)
          call pf%comm%send(pf, F, F%level*100+k, .true.)

          !! go up the v-cycle
          do l = 2, pf%nlevels
             pf%state%cycle = pf%state%cycle + 1
             F => pf%levels(l)
             G => pf%levels(l-1)

             call interpolate_time_space(pf, t0, dt, F, G,G%Finterp)

             call pf%comm%recv(pf, F, F%level*100+k, .false.)

             if (pf%rank > 0) then
                ! Interpolate increment to q0
                !  The fine initial condition needs the same increment that qSDC(1) got, but
                !  applied to the new fine initial condition
                call interpolate_q0(pf,F, G)

             end if
             !  MMM  Q: why no sweep at finest level?
             !  MMM  A: because it is done first thing in new iteration
             !  MMM  If this were the last iteration, we might want to do it anyway
             if (l < pf%nlevels .or. k .eq. pf%niters) then
!             if (l < pf%nlevels) then
                do j = 1, F%nsweeps
                   call F%sweeper%sweep(pf, F, t0, dt)
                end do
                call call_hooks(pf, F%level, PF_POST_SWEEP)
             end if
          end do

          ! XXX
          ! if (F%residual_tol > 0.0_pfdp) then
          !    call pf_compute_residual(F%q0, dt, F%F, &
          !         F%nvars, F%nnodes, F%smat, F%qend, res)
          !    if (res < F%residual_tol) then
          !       print '("serial residual condition met after: ",i3," iterations",i3)', k
          !       exit
          !    end if
          ! end if

          call call_hooks(pf, pf%nlevels, PF_POST_ITERATION)
          call end_timer(pf, TITERATION)
       end do

       call call_hooks(pf, -1, PF_POST_STEP)

       ! broadcast fine qend (non-pipelined time loop)
       if (nblock > 1) then
          F => pf%levels(pf%nlevels)

          call pf%comm%wait(pf, pf%nlevels)
          call F%encap%pack(F%send, F%qend)
          call pf%comm%broadcast(pf, F%send, F%nvars, pf%comm%nproc-1)
          F%q0 = F%send
       end if

    end do

    pf%state%iter = -1
    call end_timer(pf, TTOTAL)

    if (present(qend)) then
       F => pf%levels(pf%nlevels)
       call F%encap%copy(qend, F%qend)
    end if
  end subroutine pf_pfasst_run

end module pf_mod_parallel
