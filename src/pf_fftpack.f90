!!  Module of FFT based routines using fftpack
!
! This file is part of LIBPFASST.
!
!>  Module for using fftpack
module pf_mod_fftpackage
  use pf_mod_dtype
  use pf_mod_utils
  implicit none
  
  real(pfdp), parameter :: two_pi = 6.2831853071795862_pfdp
  !>  Variables and storage for FFT
  type  :: pf_fft_t
     integer ::   nx,ny,nz                         !! grid sizes
     integer ::   dim                              !! spatial dimension
     integer ::   lensavx, lensavy, lensavz        !! workspace lengths
     real(pfdp) :: Lx, Ly, Lz                      !! domain size
     real(pfdp) :: normfact                        !! normalization factor
     real(pfdp), allocatable :: wsavex(:)          ! work space
     real(pfdp), allocatable :: wsavey(:)          ! work space
     real(pfdp), allocatable :: wsavez(:)          ! work space     
     complex(pfdp), pointer :: workhatx(:)         ! work space
     complex(pfdp), pointer :: workhaty(:)         ! work space
     complex(pfdp), pointer :: workhatz(:)         ! work space
     
     complex(pfdp), pointer :: wk_1d(:)            ! work space
     complex(pfdp), pointer :: wk_2d(:,:)          ! work space
     complex(pfdp), pointer :: wk_3d(:,:,:)        ! work space                    
   contains
     procedure :: fft_setup
     procedure :: fft_destroy
     procedure :: fftf   !  Forward FFT
     procedure :: fftb   !  Inverse (backward)  FFT
     !  Convolution in spectral space     
     procedure, private :: conv_1d, conv_2d, conv_3d  
     generic :: conv => conv_1d, conv_2d, conv_3d  
     !  Complex convolution in real space     
     procedure, private :: zconv_1d, zconv_2d, zconv_3d  
     generic :: zconv => zconv_1d, zconv_2d, zconv_3d  
     !  Convenience function to grab pointer to workspace
     procedure , private :: get_wk_ptr_1d, get_wk_ptr_2d, get_wk_ptr_3d  
     generic   :: get_wk_ptr =>get_wk_ptr_1d,get_wk_ptr_2d,get_wk_ptr_3d
     !  Construct spectral Laplacian
     procedure , private :: make_lap_1d,make_lap_2d, make_lap_3d
     generic   :: make_lap =>make_lap_1d,make_lap_2d,make_lap_3d
     !  Construct spectral derivative
     procedure , private :: make_deriv_1d,make_deriv_2d, make_deriv_3d
     generic   :: make_deriv =>make_deriv_1d,make_deriv_2d,make_deriv_3d
  end type pf_fft_t

  
contains
  ! Convolve g with spectral op and return in c
  subroutine conv_1d(this, g,op,c)
    class(pf_fft_t), intent(inout) :: this
    real(pfdp), intent(inout) :: g(:)
    complex(pfdp), intent(in) :: op(:)
    real(pfdp), intent(inout) :: c(:)

    this%wk_1d=g
    call fftf(this)
    this%wk_1d = this%wk_1d * op
    call fftb(this)
    c=real(this%wk_1d)
  end subroutine conv_1d

  ! Convolve g with spectral op and return in c
  subroutine conv_2d(this, g,op,c)
    class(pf_fft_t), intent(inout) :: this
    real(pfdp), intent(in) :: g(:,:)
    complex(pfdp), intent(in) :: op(:,:)
    real(pfdp), intent(inout) :: c(:,:)
    this%wk_2d=g
    ! Compute Convolution
    call fftf(this)
    this%wk_2d = this%wk_2d * op
    call fftb(this)
    c=real(this%wk_2d)        
  end subroutine conv_2d
  
  subroutine conv_3d(this, g,op,c)
        class(pf_fft_t), intent(inout) :: this
    real(pfdp), intent(in) :: g(:,:,:)
    complex(pfdp), intent(in) :: op(:,:,:)
    real(pfdp), intent(inout) :: c(:,:,:)
    this%wk_3d=g
    ! Compute Convolution
    call fftf(this)
    this%wk_3d = this%wk_3d * op
    call fftb(this)
    c=real(this%wk_3d)            
  end subroutine conv_3d

 subroutine get_wk_ptr_1d(this,wk) 
    class(pf_fft_t), intent(inout) :: this
    complex(pfdp), pointer,intent(inout) :: wk(:)              ! work space
    wk=>this%wk_1d
  end subroutine get_wk_ptr_1d
  subroutine get_wk_ptr_2d(this,wk) 
    class(pf_fft_t), intent(inout) :: this
    complex(pfdp), pointer,intent(inout) :: wk(:,:)              ! work space
    wk=>this%wk_2d
  end subroutine get_wk_ptr_2d
  subroutine get_wk_ptr_3d(this,wk) 
    class(pf_fft_t), intent(inout) :: this
    complex(pfdp), pointer,intent(inout) :: wk(:,:,:)              ! work space
    wk=>this%wk_3d
  end subroutine get_wk_ptr_3d
  !>  Allocate and initialize FFT structure
  subroutine fft_setup(this, grid_shape, dim, grid_size)
    class(pf_fft_t), intent(inout) :: this
    integer,              intent(in   ) :: dim
    integer,              intent(in   ) :: grid_shape(dim)
    real(pfdp), optional, intent(in   ) :: grid_size(dim)    
      
    integer     :: nx,ny,nz
    this%dim=dim
    
    !  FFT Storage parameters
    nx=grid_shape(1)
    this%nx = nx
    this%lensavx = 4*nx + 15
    this%normfact=nx
    
    allocate(this%workhatx(nx))   !  complex transform
    allocate(this%wsavex(this%lensavx))
    this%Lx = 1.0_pfdp
    if(present(grid_size)) this%Lx = grid_size(1)
    !  Initialize FFT
    call ZFFTI( nx, this%wsavex )
    if (dim > 1) then
       !  FFT Storage
       ny=grid_shape(2)       
       this%ny = ny
       this%lensavy = 4*ny + 15
       this%normfact=nx*ny
       allocate(this%workhaty(ny))   !  complex transform
       allocate(this%wsavey(this%lensavy))
       this%Ly = 1.0_pfdp
       if(present(grid_size)) this%Ly = grid_size(2)
       !  Initialize FFT
       call ZFFTI( ny, this%wsavey)
       
       if (dim > 2) then
          !  FFT Storage
          nz=grid_shape(3)       
          this%nz = nz
          this%lensavz = 4*nz + 15
          this%normfact=nx*ny*nz             
          allocate(this%workhatz(nz))   !  complex transform
          allocate(this%wsavez(this%lensavz))
          this%Lz = 1.0_pfdp
          if(present(grid_size)) this%Lz = grid_size(3)
          !  Initialize FFT
          call ZFFTI( nz, this%wsavez)
       endif
    endif
    select case (this%dim)
    case (1)            
       allocate(this%wk_1d(nx))
    case (2)            
       allocate(this%wk_2d(nx,ny))
    case (3)            
       allocate(this%wk_3d(nx,ny,nz))
    case DEFAULT
       call pf_stop(__FILE__,__LINE__,'Bad case in SELECT',this%dim)
    end select
  end subroutine fft_setup

  !>  Deallocate and destroy fft structures
  subroutine fft_destroy(this)
    class(pf_fft_t), intent(inout) :: this
    deallocate(this%workhatx)
    deallocate(this%wsavex)
    if (this%dim > 1) then
       deallocate(this%workhaty)
       deallocate(this%wsavey)
       if (this%dim > 2) then
          deallocate(this%workhatz)
          deallocate(this%wsavez)
       end if
    end if
    select case (this%dim)
    case (1)            
       deallocate(this%wk_1d)
    case (2)            
       deallocate(this%wk_2d)
    case (3)            
       deallocate(this%wk_3d)
    case DEFAULT
       call pf_stop(__FILE__,__LINE__,'Bad case in SELECT',this%dim)
    end select
    
  end subroutine fft_destroy

  !>  Forward fft call
  subroutine fftf(this)
    class(pf_fft_t), intent(inout) :: this
    
    integer i,j,k
    
    select case (this%dim)       
    case (1)            
       call zfftf(this%nx, this%wk_1d, this%wsavex )
    case (2)
       do j = 1,this%ny
          this%workhatx =this%wk_2d(:,j)
          call zfftf(this%nx, this%workhatx, this%wsavex )
          this%wk_2d(:,j)=this%workhatx
       end do
       do i = 1,this%nx
          this%workhaty =this%wk_2d(i,:)
          call zfftf(this%ny, this%workhaty, this%wsavey )
          this%wk_2d(i,:)=this%workhaty
       end do
    case (3)            
       do k = 1,this%nz
          do j = 1,this%ny
             this%workhatx =this%wk_3d(:,j,k)
             call zfftf(this%nx, this%workhatx, this%wsavex )
             this%wk_3d(:,j,k)=this%workhatx
          end do
       end do
       do k = 1,this%nz
          do i = 1,this%nx
             this%workhaty =this%wk_3d(i,:,k)
             call zfftf(this%ny, this%workhaty, this%wsavey )
             this%wk_3d(i,:,k)=this%workhaty
          end do
       end do
       do j = 1,this%ny
          do i = 1,this%nx
             this%workhatz =this%wk_3d(i,j,:)
             call zfftf(this%nz, this%workhatz, this%wsavez)
             this%wk_3d(i,j,:)=this%workhatz
          end do
       end do
    case DEFAULT
       call pf_stop(__FILE__,__LINE__,'Bad case in SELECT',this%dim)
    end select
  end subroutine fftf

  !  Backward FFT
  subroutine fftb(this)
    class(pf_fft_t), intent(inout) :: this
    
    integer i,j,k
    
    select case (this%dim)       
    case (1)
       this%wk_1d=this%wk_1d/this%normfact                                              
       call zfftb(this%nx, this%wk_1d, this%wsavex )
    case (2)
       this%wk_2d=this%wk_2d/this%normfact                                    
       do j = 1,this%ny
          this%workhatx =this%wk_2d(:,j)
          call zfftb(this%nx, this%workhatx, this%wsavex )
          this%wk_2d(:,j)=this%workhatx
       end do
       do i = 1,this%nx
          this%workhaty =this%wk_2d(i,:)
          call zfftb(this%ny, this%workhaty, this%wsavey )
          this%wk_2d(i,:)=this%workhaty
       end do
    case (3)            
       this%wk_3d=this%wk_3d/this%normfact                          
       do k = 1,this%nz
          do j = 1,this%ny
             this%workhatx =this%wk_3d(:,j,k)
             call zfftb(this%nx, this%workhatx, this%wsavex )
             this%wk_3d(:,j,k)=this%workhatx
          end do
       end do
       do k = 1,this%nz
          do i = 1,this%nx
             this%workhaty =this%wk_3d(i,:,k)
             call zfftb(this%ny, this%workhaty, this%wsavey )
             this%wk_3d(i,:,k)=this%workhaty
          end do
       end do
       do j = 1,this%ny
          do i = 1,this%nx
             this%workhatz =this%wk_3d(i,j,:)
             call zfftb(this%nz, this%workhatz, this%wsavez)
             this%wk_3d(i,j,:)=this%workhatz
          end do
       end do
    case DEFAULT
       call pf_stop(__FILE__,__LINE__,'Bad case in SELECT',this%dim)
    end select
  end subroutine fftb
  
  ! START private convolution procedures
    
  subroutine zconv_1d(this, g)
    ! Variable Types
        class(pf_fft_t), intent(inout) :: this
        real(pfdp), intent(in) :: g(:)
        ! Compute Convolution
        call fftb(this)
        this%wk_1d = this%wk_1d * g
        call fftf(this)
    end subroutine zconv_1d

    subroutine zconv_2d(this, g)
        ! Variable Types
        class(pf_fft_t), intent(inout) :: this
        real(pfdp), intent(in) :: g(:,:)
        ! Compute Convolution
        call fftb(this)
        this%wk_2d = this%wk_2d * g
        call fftf(this)
    end subroutine zconv_2d

    subroutine zconv_3d(this, g)
        ! Variable Types
        class(pf_fft_t), intent(inout) :: this
        real(pfdp), intent(in) :: g(:,:,:)
        ! Compute Convolution
        call fftb(this)
        this%wk_3d = this%wk_3d * g
        call fftf(this)
    end subroutine zconv_3d
    
    subroutine make_lap_1d(this, lap)
      class(pf_fft_t), intent(inout) :: this
      complex(pfdp), intent(inout) :: lap(:)
      
      integer     :: i,nx
      real(pfdp)  :: kx, Lx
      
      nx=this%nx
      Lx=this%Lx
      do i = 1, nx
         if (i <= nx/2+1) then
            kx = two_pi / Lx * dble(i-1)
         else
            kx = two_pi / Lx * dble(-nx + i - 1)
         end if
         lap(i) = -kx**2
      end do
      
    end subroutine make_lap_1d
    subroutine make_deriv_1d(this, ddx)
      class(pf_fft_t), intent(inout) :: this
      complex(pfdp), intent(inout) :: ddx(:)
      
      integer     :: i,nx
      real(pfdp)  :: kx, Lx
      
      nx=this%nx
      Lx=this%Lx
      do i = 1, nx
         if (i <= nx/2+1) then
            kx = two_pi / Lx * dble(i-1)
         else
            kx = two_pi / Lx * dble(-nx + i - 1)
         end if
         
         ddx(i) = (0.0_pfdp, 1.0_pfdp) * kx
      end do
    end subroutine make_deriv_1d
     
    subroutine make_lap_2d(this, lap)
      class(pf_fft_t), intent(inout) :: this
      complex(pfdp), intent(inout) :: lap(:,:)
      
      integer     :: i,j,nx,ny
      real(pfdp)  :: kx,ky,Lx,Ly
      
      nx=this%nx
      ny=this%ny
      Lx=this%Lx
      Ly=this%Ly
      
      do j = 1, ny
         if (j <= ny/2+1) then
            ky = two_pi / Ly * dble(j-1)
         else
            ky = two_pi / Ly * dble(-ny + j - 1)
         end if
         do i = 1, nx
            if (i <= nx/2+1) then
               kx = two_pi / Lx * dble(i-1)
            else
               kx = two_pi / Lx * dble(-nx + i - 1)
            end if
            
            lap(i,j) = -(kx**2+ky**2)
         end do
      end do
    end subroutine make_lap_2d

    subroutine make_deriv_2d(this, deriv,dir)
      class(pf_fft_t), intent(inout) :: this
      complex(pfdp), intent(inout) :: deriv(:,:)
      integer, intent(in) :: dir
      
      integer     :: i,j,nx,ny
      real(pfdp)  :: kx,ky,Lx,Ly
      
      nx=this%nx
      ny=this%ny
      Lx=this%Lx
      Ly=this%Ly
      
      do j = 1, ny
         if (j <= ny/2+1) then
            ky = two_pi / Ly * dble(j-1)
         else
            ky = two_pi / Ly * dble(-ny + j - 1)
         end if
         do i = 1, nx
            if (i <= nx/2+1) then
               kx = two_pi / Lx * dble(i-1)
            else
               kx = two_pi / Lx * dble(-nx + i - 1)
            end if
            
            if (dir .eq. 1) then
               deriv(i,j) = (0.0_pfdp,1.0_pfdp)*kx
            else
               deriv(i,j) = (0.0_pfdp,1.0_pfdp)*ky
            endif
         end do
      end do
    end subroutine make_deriv_2d


    subroutine make_lap_3d(this, lap)
      class(pf_fft_t), intent(inout) :: this
      complex(pfdp), intent(inout) :: lap(:,:,:)
      
      integer     :: i,j,k,nx,ny,nz
      real(pfdp)  :: kx,ky,kz,Lx,Ly,Lz
      
      nx=this%nx
      ny=this%ny
      nz=this%nz
      Lx=this%Lx
      Ly=this%Ly
      Lz=this%Lz
      do k = 1,nz
         if (k <= nz/2+1) then
            kz = two_pi / Lz * dble(k-1)
         else
            kz = two_pi / Ly * dble(-nz + k - 1)
         end if
         do j = 1, ny
            if (j <= ny/2+1) then
               ky = two_pi / Ly * dble(j-1)
            else
               ky = two_pi / Ly * dble(-ny + j - 1)
            end if
            do i = 1, nx
               if (i <= nx/2+1) then
                  kx = two_pi / Lx * dble(i-1)
               else
                  kx = two_pi / Lx * dble(-nx + i - 1)
               end if
               lap(i,j,k) = -(kx**2+ky**2+kz**2)
            end do
         end do
      end do
      
    end subroutine make_lap_3d

    subroutine make_deriv_3d(this, deriv,dir)
      class(pf_fft_t), intent(inout) :: this
      complex(pfdp), intent(inout) :: deriv(:,:,:)
      integer, intent(in) :: dir
      
      integer     :: i,j,k,nx,ny,nz
      real(pfdp)  :: kx,ky,kz,Lx,Ly,Lz
      
      nx=this%nx
      ny=this%ny
      nz=this%nz       
      Lx=this%Lx
      Ly=this%Ly
      Lz=this%Lz
      
      select case (dir)
      case (1)  
         do i = 1, nx
            if (i <= nx/2+1) then
               kx = two_pi / Lx * dble(i-1)
            else
               kx = two_pi / Lx * dble(-nx + i - 1)
            end if
            deriv(i,:,:) = (0.0_pfdp,1.0_pfdp)*kx
         end do
      case (2)
         do j = 1, ny
            if (j <= ny/2+1) then
               ky = two_pi / Ly * dble(j-1)
            else
               ky = two_pi / Ly * dble(-ny + j - 1)
            end if
            deriv(:,j,:) = (0.0_pfdp,1.0_pfdp)*ky
         end do
      case (3)
         do k = 1, nz
            if (k <= nz/2+1) then
               kz = two_pi / Lz * dble(k-1)
            else
               kz = two_pi / Ly * dble(-nz + k - 1)
            end if
            deriv(:,:,k) = (0.0_pfdp,1.0_pfdp)*kz
         end do
      case DEFAULT
         call pf_stop(__FILE__,__LINE__,'Bad case in SELECT',dir)
      end select

    end subroutine make_deriv_3d
    
  end module pf_mod_fftpackage
   



