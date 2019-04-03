!!  IMEX Sweeper Module
!
! This file is part of LIBPFASST.
!
!>  IMEX Sweeper Module
!!  Module of the  the derived sweeper class for doing IMEX sweeps for an equation of the form
!!         $$   y' = f_1(y) + f_2(y)  $$
!!  The \(f_1\) piece is treated explicitly and \(f_2\) implicitl
!!  Afer this sweeper is initialized (usually in main), the logical flags can be changed if desired
!!
!!     explicit:  Make false if there is no explicit piece
!!
!!     implicit:  Make false if there is no implicit piece
!!
!!  The user needs to supply the feval and fcomp routines for a given example
module pf_mod_imex_sweeper
  use pf_mod_dtype
  use pf_mod_utils

  implicit none

  !>  IMEX SDC sweeper type, extends abstract sweeper
  type, extends(pf_sweeper_t), abstract :: pf_imex_sweeper_t
     real(pfdp), allocatable :: QtilE(:,:)   !!  Approximate explicit quadrature rule
     real(pfdp), allocatable :: QtilI(:,:)   !!  Approximate implicit quadrature rule
     real(pfdp), allocatable :: dtsdc(:)     !!  SDC step sizes
     real(pfdp), allocatable :: QdiffE(:,:)  !!  qmat-QtilE
     real(pfdp), allocatable :: QdiffI(:,:)  !!  qmat-QtilI

     logical    :: explicit  !!  True if there is an explicit piece (must set in derived sweeper)
     logical    :: implicit  !!  True if there an implicit piece (must set in derived sweeper)

     class(pf_encap_t), allocatable :: rhs   !! holds rhs for implicit solve

   contains
     procedure(pf_f_eval_p), deferred :: f_eval   !!  RHS function evaluations
     procedure(pf_f_comp_p), deferred :: f_comp   !!  Implicit solver
     !>  Set the generic functions
     procedure :: sweep      => imex_sweep
     procedure :: initialize => imex_initialize
     procedure :: evaluate   => imex_evaluate
     procedure :: integrate  => imex_integrate
     procedure :: residual   => imex_residual
     procedure :: spreadq0   => imex_spreadq0
     procedure :: evaluate_all => imex_evaluate_all
     procedure :: destroy   => imex_destroy
     procedure :: imex_destroy
     procedure :: imex_initialize
  end type pf_imex_sweeper_t

  interface
     !>  The interface to the routine to compute the RHS function values
     !>  Evaluate f_piece(y), where piece is one or two
     subroutine pf_f_eval_p(this,y, t, level_index, f, piece)
       import pf_imex_sweeper_t, pf_encap_t, pfdp
       class(pf_imex_sweeper_t),  intent(inout) :: this
       class(pf_encap_t), intent(in   )  :: y           !!  Argument for evaluation
       real(pfdp),        intent(in   )  :: t           !!  Time at evaluation
       integer,    intent(in   )         :: level_index !!  Level index
       class(pf_encap_t), intent(inout)  :: f           !!  RHS function value
       integer,    intent(in   )         :: piece       !!  Which piece to evaluate
     end subroutine pf_f_eval_p

     !>  The interface to the routine to do implicit solve 
     !>  i.e, solve the equation y - dtq*f_2(y) =rhs
     subroutine pf_f_comp_p(this,y, t, dtq, rhs, level_index, f, piece)
       import pf_imex_sweeper_t, pf_encap_t, pfdp
       class(pf_imex_sweeper_t),  intent(inout) :: this
       class(pf_encap_t), intent(inout)  :: y           !!  Solution of implicit solve
       real(pfdp),        intent(in   )  :: t           !!  Time of solve
       real(pfdp),        intent(in   )  :: dtq         !!  dt*quadrature weight
       class(pf_encap_t), intent(in   )  :: rhs         !!  RHS for solve
       integer,    intent(in   )         :: level_index !!  Level index
       class(pf_encap_t), intent(inout) :: f            !!  f_2 of solution y
       integer,    intent(in   ) :: piece               !!  Which piece to evaluate
     end subroutine pf_f_comp_p
  end interface

contains

  !> Perform nsweeps SDC sweeps on level level_index and set qend appropriately.
  subroutine imex_sweep(this, pf, level_index, t0, dt,nsweeps, flags)
    use pf_mod_timer
    use pf_mod_hooks

    !>  Inputs
    class(pf_imex_sweeper_t), intent(inout) :: this
    type(pf_pfasst_t), intent(inout),target :: pf    !!  PFASST structure
    integer,           intent(in)    :: level_index  !!  level on which to sweep
    real(pfdp),        intent(in   ) :: t0           !!  time at beginning of time step
    real(pfdp),        intent(in   ) :: dt           !!  time step size
    integer,           intent(in)    :: nsweeps      !!  number of sweeps to do
    integer, optional, intent(in   ) :: flags        !!  sweep specific flags

    !>  Local variables
    type(pf_level_t), pointer :: lev    !!  points to current level

    integer     :: m, n,k   !!  Loop variables
    real(pfdp)  :: t        !!  Time at nodes

    lev => pf%levels(level_index)   !!  Assign level pointer
    
    call start_timer(pf, TLEVEL+lev%index-1)

    do k = 1,nsweeps   !!  Loop over sweeps
       pf%state%sweep=k
       call call_hooks(pf, level_index, PF_PRE_SWEEP)


       !  Add terms from previous iteration  (not passing CI tests)
       !do m = 1, lev%nnodes-1
       !   call lev%I(m)%setval(0.0_pfdp)
       !end do

       !if (this%explicit) call pf_apply_mat(lev%I, dt, this%QdiffE, lev%F(:,1), .false.)             
       !if (this%implicit) call pf_apply_mat(lev%I, dt, this%QdiffI, lev%F(:,2), .false.)

       ! compute integrals and add fas correction
       do m = 1, lev%nnodes-1
          call lev%I(m)%setval(0.0_pfdp)
          if (this%explicit) then
             do n = 1, lev%nnodes
                call lev%I(m)%axpy(dt*this%QdiffE(m,n), lev%F(n,1))
             end do
          end if
          if (this%implicit) then
             do n = 1, lev%nnodes
                call lev%I(m)%axpy(dt*this%QdiffI(m,n), lev%F(n,2))
             end do
          end if
       end do

       !  Add the tau FAS correction
       if (level_index < pf%state%finest_level) then
          do m = 1, lev%nnodes-1
             call lev%I(m)%axpy(1.0_pfdp, lev%tauQ(m))
             if (m>1 .and. pf%use_Sform) then
                call lev%I(m)%axpy(-1.0_pfdp, lev%tauQ(m-1))
             end if
          end do
       end if
       
       !  Recompute the first function value if this is first sweep
       if (k .eq. 1) then
          call lev%Q(1)%copy(lev%q0)
          if (this%explicit) &
               call this%f_eval(lev%Q(1), t0, lev%index, lev%F(1,1),1)
          if (this%implicit) &
               call this%f_eval(lev%Q(1), t0, lev%index, lev%F(1,2),2)
       end if

       t = t0
       ! do the sub-stepping in sweep
       do m = 1, lev%nnodes-1  !!  Loop over substeps
          t = t + dt*this%dtsdc(m)

          !>  Accumulate rhs
          call this%rhs%setval(0.0_pfdp)
          do n = 1, m
             if (this%explicit) &
                  call this%rhs%axpy(dt*this%QtilE(m,n), lev%F(n,1))
             if (this%implicit) &
                  call this%rhs%axpy(dt*this%QtilI(m,n), lev%F(n,2))
          end do
          !>  Add the integral term
          call this%rhs%axpy(1.0_pfdp, lev%I(m))

          !>  Add the starting value
          if (pf%use_Sform) then
             call this%rhs%axpy(1.0_pfdp, lev%Q(m))
          else
             call this%rhs%axpy(1.0_pfdp, lev%Q(1))
          end if

          !>  Solve for the implicit piece
          if (this%implicit) then
             call this%f_comp(lev%Q(m+1), t, dt*this%QtilI(m,m+1), this%rhs, lev%index,lev%F(m+1,2),2)
          else
             call lev%Q(m+1)%copy(this%rhs)
          end if
          !>  Compute explicit function on new value
          if (this%explicit) &
               call this%f_eval(lev%Q(m+1), t, lev%index, lev%F(m+1,1),1)


       end do  !!  End substep loop
       call pf_residual(pf, level_index, dt)
       call lev%qend%copy(lev%Q(lev%nnodes))

       call call_hooks(pf, level_index, PF_POST_SWEEP)
    end do  !  End loop on sweeps

    call end_timer(pf, TLEVEL+lev%index-1)
  end subroutine imex_sweep

  !> Subroutine to initialize matrices and space for sweeper
  subroutine imex_initialize(this, pf, level_index)
    use pf_mod_quadrature
    class(pf_imex_sweeper_t), intent(inout) :: this
    type(pf_pfasst_t), intent(inout),target :: pf    !!  PFASST structure
    integer,           intent(in)    :: level_index  !!  level on which to initialize

    type(pf_level_t), pointer  :: lev    !!  Current level

    integer    ::  nnodes,ierr
    lev => pf%levels(level_index)   !!  Assign level pointer
    this%npieces = 2

    nnodes = lev%nnodes
    print *,'nnodes',nnodes
    allocate(this%QdiffE(nnodes-1,nnodes),stat=ierr)
    if (ierr /=0) stop "allocate fail in imex_initialize for QdiffE"
    allocate(this%QdiffI(nnodes-1,nnodes),stat=ierr)
    if (ierr /=0) stop "allocate fail in imex_initialize for QdiffI"
    allocate(this%QtilE(nnodes-1,nnodes),stat=ierr)
    if (ierr /=0) stop "allocate fail in imex_initialize for QtilE"
    allocate(this%QtilI(nnodes-1,nnodes),stat=ierr)
    if (ierr /=0) stop "allocate fail in imex_initialize for QtilI"
    allocate(this%dtsdc(nnodes-1),stat=ierr)
    if (ierr /=0) stop "allocate fail in imex_initialize for dtsdc"

    this%QtilE = 0.0_pfdp
    this%QtilI = 0.0_pfdp

    !>  Array of substep sizes
    this%dtsdc = lev%sdcmats%qnodes(2:nnodes) - lev%sdcmats%qnodes(1:nnodes-1)

    ! Implicit matrix
    if (this%use_LUq) then
       this%QtilI = lev%sdcmats%qmatLU
    else
       this%QtilI =  lev%sdcmats%qmatBE
    end if

    ! Explicit matrix
    this%QtilE =  lev%sdcmats%qmatFE

    this%QdiffE = lev%sdcmats%qmat-this%QtilE
    this%QdiffI = lev%sdcmats%qmat-this%QtilI

    if (pf%use_Sform) then
          this%QdiffE(2:nnodes-1,:) = this%QdiffE(2:nnodes-1,:)- this%QdiffE(1:nnodes-2,:)
          this%QdiffI(2:nnodes-1,:) = this%QdiffI(2:nnodes-1,:)- this%QdiffI(1:nnodes-2,:)
          this%QtilE(2:nnodes-1,:) = this%QtilE(2:nnodes-1,:)- this%QtilE(1:nnodes-2,:)
          this%QtilI(2:nnodes-1,:) = this%QtilI(2:nnodes-1,:)- this%QtilI(1:nnodes-2,:)
    end if
    !>  Make space for rhs
    call lev%ulevel%factory%create_single(this%rhs, lev%index,   lev%shape)

  end subroutine imex_initialize

  !>  Subroutine to deallocate sweeper
  subroutine imex_destroy(this, pf,level_index)
    class(pf_imex_sweeper_t),  intent(inout) :: this
    type(pf_pfasst_t),  target,  intent(inout) :: pf
    integer,              intent(in)    :: level_index

    type(pf_level_t), pointer  :: lev        !!  Current level
    lev => pf%levels(level_index)   !!  Assign level pointer

    deallocate(this%QdiffE)
    deallocate(this%QdiffI)
    deallocate(this%QtilE)
    deallocate(this%QtilI)
    deallocate(this%dtsdc)

    call lev%ulevel%factory%destroy_single(this%rhs)

  end subroutine imex_destroy


  !> Subroutine to compute  Picard integral of function values
  subroutine imex_integrate(this,pf,level_index, qSDC, fSDC, dt, fintSDC, flags)
    class(pf_imex_sweeper_t), intent(inout) :: this
    type(pf_pfasst_t), intent(inout),target :: pf    !!  PFASST structure
    integer,           intent(in)    :: level_index  !!  level on which to initialize
    class(pf_encap_t), intent(in   ) :: qSDC(:)      !!  Solution values
    class(pf_encap_t), intent(in   ) :: fSDC(:, :)   !!  RHS Function values
    real(pfdp),        intent(in   ) :: dt           !!  Time step
    class(pf_encap_t), intent(inout) :: fintSDC(:)   !!  Integral from t_n to t_m
    integer, optional, intent(in   ) :: flags

    integer :: n, m
    type(pf_level_t), pointer :: lev        !!  Current level
    lev => pf%levels(level_index)   !!  Assign level pointer
    
    do n = 1, lev%nnodes-1
       call fintSDC(n)%setval(0.0_pfdp)
       do m = 1, lev%nnodes
          if (this%explicit) &
               call fintSDC(n)%axpy(dt*lev%sdcmats%qmat(n,m), fSDC(m,1))
          if (this%implicit) &
               call fintSDC(n)%axpy(dt*lev%sdcmats%qmat(n,m), fSDC(m,2))
       end do
    end do
       

!    if (this%explicit) call pf_apply_mat(fintSDC, dt, lev%sdcmats%Qmat, fSDC(:,1), .false.)    
!    if (this%implicit) call pf_apply_mat(fintSDC, dt, lev%sdcmats%Qmat, fSDC(:,2), .false.)    
  end subroutine imex_integrate


  !> Subroutine to compute  Residual
  subroutine imex_residual(this, pf, level_index, dt, flags)
    class(pf_imex_sweeper_t),  intent(inout) :: this
    type(pf_pfasst_t), intent(inout),target :: pf    !!  PFASST structure
    integer,           intent(in)    :: level_index  !!  level on which to initialize
    real(pfdp),        intent(in   ) :: dt           !!  Time step
    integer, intent(in), optional   :: flags
    
    call pf_generic_residual(this, pf, level_index, dt)
  end subroutine imex_residual


  subroutine imex_spreadq0(this, pf,level_index, t0, flags, step)
    class(pf_imex_sweeper_t),  intent(inout) :: this
    type(pf_pfasst_t), intent(inout),target :: pf    !!  PFASST structure
    integer,           intent(in)    :: level_index  !!  level on which to initialize
    real(pfdp),        intent(in   ) :: t0
    integer, optional,   intent(in)    :: flags, step

    call pf_generic_spreadq0(this, pf,level_index, t0)
  end subroutine imex_spreadq0

  !> Subroutine to evaluate function value at node m
  subroutine imex_evaluate(this, pf,level_index, t, m, flags, step)

    class(pf_imex_sweeper_t),  intent(inout) :: this
    type(pf_pfasst_t), intent(inout),target :: pf    !!  PFASST structure
    integer,           intent(in)    :: level_index  !!  level on which to initialize
    real(pfdp),        intent(in   ) :: t    !!  Time at which to evaluate
    integer,           intent(in   ) :: m    !!  Node at which to evaluate
    integer, intent(in), optional   :: flags, step

    type(pf_level_t), pointer :: lev        !!  Current level
    lev => pf%levels(level_index)   !!  Assign level pointer

    if (this%explicit) &
       call this%f_eval(lev%Q(m), t, lev%index, lev%F(m,1),1)
    if (this%implicit) &
         call this%f_eval(lev%Q(m), t, lev%index, lev%F(m,2),2)
  end subroutine imex_evaluate

  !> Subroutine to evaluate the function values at all nodes
  subroutine imex_evaluate_all(this, pf,level_index, t, flags, step)
    class(pf_imex_sweeper_t),  intent(inout) :: this
    type(pf_pfasst_t), intent(inout),target :: pf    !!  PFASST structure
    integer,           intent(in)    :: level_index  !!  level on which to initialize
    real(pfdp),        intent(in   ) :: t(:)  !!  Array of times at each node
    integer, intent(in), optional   :: flags, step
    
    call pf_generic_evaluate_all(this, pf,level_index, t)
  end subroutine imex_evaluate_all

end module pf_mod_imex_sweeper
