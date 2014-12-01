!
! This module defines ssids_fkeep type and associated procedures (CPU version)
!
module spral_ssids_fkeep_gpu
   use spral_cuda, only : cudaMemcpy_d2h, cudaMemcpy_h2d, cudaMalloc, cudaFree,&
                          c_ptr_plus, cudaStreamCreate, cudaStreamDestroy, &
                          cudaMemcpy2d, cudaMemcpyHostToDevice, &
                          cudaMemcpyDeviceToHost
   use spral_ssids_alloc, only : smalloc
   use spral_ssids_cuda_datatypes, only : gpu_type, free_gpu_type
   use spral_ssids_cuda_interfaces, only : push_ssids_cuda_settings, &
                          pop_ssids_cuda_settings, cuda_settings_type, scale
   use spral_ssids_datatypes, only : long, node_type, smalloc_type, &
                                     ssids_akeep, ssids_options, &
                                     ssids_inform, thread_stats, wp, &
                                     ssids_print_flag, &
                                     SSIDS_ERROR_ALLOCATION, &
                                     SSIDS_ERROR_CUDA_UNKNOWN, &
                                     SSIDS_SOLVE_JOB_ALL, SSIDS_SOLVE_JOB_BWD, &
                                     SSIDS_SOLVE_JOB_DIAG, SSIDS_SOLVE_JOB_FWD,&
                                     SSIDS_SOLVE_JOB_DIAG_BWD
   use spral_ssids_factor_gpu, only : parfactor
   use spral_ssids_fkeep, only : ssids_fkeep
   use spral_ssids_solve_cpu, only : solve_calc_chunk, inner_solve, &
                                     subtree_bwd_solve
   use spral_ssids_solve_gpu, only : bwd_solve_gpu, fwd_solve_gpu, &
                                     fwd_multisolve_gpu, bwd_multisolve_gpu, &
                                     d_solve_gpu
   use, intrinsic :: iso_c_binding
   implicit none

   private
   public :: ssids_fkeep_gpu

   !
   ! Data type for data generated in factorise phase (gpu version)
   !
   type, extends(ssids_fkeep) :: ssids_fkeep_gpu
      type(C_PTR), dimension(:), allocatable :: stream_handle
      type(gpu_type), dimension(:), allocatable :: stream_data
      type(gpu_type) :: top_data
      type(C_PTR) :: gpu_rlist_with_delays = C_NULL_PTR
      type(C_PTR) :: gpu_rlist_direct_with_delays = C_NULL_PTR
      type(C_PTR) :: gpu_clists = C_NULL_PTR
      type(C_PTR) :: gpu_clists_direct = C_NULL_PTR
      type(C_PTR) :: gpu_clen = C_NULL_PTR
      logical :: host_factors = .false.

   contains
      procedure, pass(fkeep) :: inner_factor => inner_factor_gpu ! Do actual factorization
      procedure, pass(fkeep) :: free => free_fkeep_gpu ! Frees memory
      procedure, pass(fkeep) :: inner_solve => inner_solve_gpu ! Do actual solve
   end type ssids_fkeep_gpu

contains

subroutine inner_factor_gpu(fkeep, akeep, val, options, inform)
   class(ssids_akeep), intent(in) :: akeep
   class(ssids_fkeep_gpu), intent(inout) :: fkeep
   real(wp), dimension(*), target, intent(in) :: val
   class(ssids_options), intent(in) :: options
   class(ssids_inform), intent(inout) :: inform

   integer :: i
   type(C_PTR) :: gpu_val, gpu_scaling
   type(C_PTR), dimension(:), allocatable :: gpu_contribs
   integer(long) :: sz
   integer, dimension(:,:), allocatable :: map ! work array, one copy per
      ! thread. Size (0:n, num_threads), with 0 index used to track which
      ! node current map refers to.
   type(thread_stats), dimension(:), allocatable :: stats ! one copy
      ! per thread, accumulates per thread statistics that are then summed to
      ! obtain global stats in inform.

   integer :: num_threads
   integer :: cuda_error, st

   num_threads = 1
!$ num_threads = omp_get_max_threads()

   fkeep%host_factors = .false.

   allocate(stats(num_threads), map(0:akeep%n, num_threads), stat=st)
   if (st .ne. 0) go to 10
   map(0, :) = -1 ! initally map unassociated with any node

   ! Setup child contribution array
   ! Note: only non-NULL where we're passing contributions between subtrees
   allocate(gpu_contribs(akeep%nnodes), stat=st)
   if(st.ne.0) goto 10
   gpu_contribs(:) = C_NULL_PTR

   ! Copy A values to GPU
   sz = akeep%nptr(akeep%nnodes+1) - 1
   cuda_error = cudaMalloc(gpu_val, C_SIZEOF(val(1:sz)))
   if(cuda_error.ne.0) goto 200
   cuda_error = cudaMemcpy_h2d(gpu_val, C_LOC(val), C_SIZEOF(val(1:sz)))
   if(cuda_error.ne.0) goto 200
   
   ! Allocate and initialize streams
   if(allocated(fkeep%stream_handle)) then
      if(size(fkeep%stream_handle).lt.options%nstream) then
         do i = 1, size(fkeep%stream_handle)
            if(C_ASSOCIATED(fkeep%stream_handle(i))) then
               cuda_error = cudaStreamDestroy(fkeep%stream_handle(i))
               if(cuda_error.ne.0) goto 200
            endif
         end do
         deallocate(fkeep%stream_handle, stat=st)
         if(st.ne.0) goto 10
      endif
   endif
   if(.not.allocated(fkeep%stream_handle)) then
      allocate(fkeep%stream_handle(options%nstream), stat=st)
      if(st.ne.0) goto 10
      do i = 1, options%nstream
         cuda_error = cudaStreamCreate(fkeep%stream_handle(i))
         if(cuda_error.ne.0) goto 200
      end do
   endif

   ! Cleanup/allocate factor datastructures
   ! FIXME: We should move node<->level assignment to analyze then we can
   ! more easily reuse stream_data
   call free_gpu_type(fkeep%top_data, cuda_error)
   if(allocated(fkeep%stream_data)) then
      do i = 1, size(fkeep%stream_data)
         call free_gpu_type(fkeep%stream_data(i), cuda_error)
         if(cuda_error.ne.0) goto 200
      end do
      deallocate(fkeep%stream_data, stat=st)
      if(st.ne.0) goto 10
   endif
   allocate(fkeep%stream_data(options%nstream), stat=st)
   if (st.ne.0) goto 10

   ! Call main factorization routine
   if (allocated(fkeep%scaling)) then
      ! Copy scaling vector to GPU
      cuda_error = cudaMalloc(gpu_scaling, C_SIZEOF(fkeep%scaling(1:akeep%n)))
      if(cuda_error.ne.0) goto 200
      cuda_error = copy_to_gpu_non_target(gpu_scaling, fkeep%scaling, &
         C_SIZEOF(fkeep%scaling(1:akeep%n)))
      if(cuda_error.ne.0) goto 200

      ! Perform factorization
      call parfactor(fkeep%pos_def, akeep%child_ptr, akeep%child_list, akeep%n,&
         akeep%nptr, akeep%gpu_nlist, gpu_val, akeep%nnodes, fkeep%nodes,      &
         akeep%sptr, akeep%sparent, akeep%rptr, akeep%rlist, akeep%invp,       &
         akeep%rlist_direct, akeep%gpu_rlist, akeep%gpu_rlist_direct,          &
         gpu_contribs, fkeep%stream_handle, fkeep%stream_data,                 &
         fkeep%top_data, fkeep%gpu_rlist_with_delays,                          &
         fkeep%gpu_rlist_direct_with_delays, fkeep%gpu_clists,                 &
         fkeep%gpu_clists_direct, fkeep%gpu_clen, fkeep%alloc, options, stats, &
         ptr_scale=gpu_scaling)
      cuda_error = cudaFree(gpu_scaling)
      if(cuda_error.ne.0) goto 200
   else
      call parfactor(fkeep%pos_def, akeep%child_ptr, akeep%child_list, akeep%n,&
         akeep%nptr, akeep%gpu_nlist, gpu_val, akeep%nnodes, fkeep%nodes,      &
         akeep%sptr, akeep%sparent, akeep%rptr, akeep%rlist, akeep%invp,       &
         akeep%rlist_direct, akeep%gpu_rlist, akeep%gpu_rlist_direct,          &
         gpu_contribs, fkeep%stream_handle, fkeep%stream_data,                 &
         fkeep%top_data, fkeep%gpu_rlist_with_delays,                          &
         fkeep%gpu_rlist_direct_with_delays, fkeep%gpu_clists,                 &
         fkeep%gpu_clists_direct, fkeep%gpu_clen, fkeep%alloc, options, stats)
   end if

   cuda_error = cudaFree(gpu_val)
   if(cuda_error.ne.0) goto 200
   
   ! Do reductions
   i = minval(stats(:)%flag)
   if(i.lt.0) then
      inform%flag = i
      inform%stat = maxval(stats(:)%st)
      if(inform%stat.eq.0) inform%stat = minval(stats(:)%st)
      ! Note: cuda_error and cublas_error are actually C enums, so are +ive
      if(inform%cuda_error.eq.0) inform%cuda_error = maxval(stats(:)%cuda_error)
      if(inform%cublas_error.eq.0) &
         inform%cublas_error = maxval(stats(:)%cublas_error)
      st = inform%stat
   end if
   i = max(inform%flag, maxval(stats(:)%flag))
   inform%maxfront = maxval(stats(:)%maxfront)
   inform%num_factor = sum(stats(:)%num_factor)
   inform%num_flops = sum(stats(:)%num_flops)
   inform%num_delay = sum(stats(:)%num_delay)
   inform%num_neg = sum(stats(:)%num_neg)
   inform%num_two = sum(stats(:)%num_two)
   inform%matrix_rank = akeep%sptr(akeep%nnodes+1)-1 - sum(stats(:)%num_zero)
   fkeep%flag = inform%flag
   return
   !!!!!!!!!!!!!!!!!!!!

   !
   ! Error handling
   !
   10 continue
   inform%flag = SSIDS_ERROR_ALLOCATION
   inform%stat = st
   fkeep%flag = inform%flag
   return

   200 continue
   inform%flag = SSIDS_ERROR_CUDA_UNKNOWN
   inform%cuda_error = cuda_error
   fkeep%flag = inform%flag
   return
end subroutine inner_factor_gpu

subroutine inner_solve_gpu(local_job, nrhs, x, ldx, akeep, fkeep, options, inform)
   class(ssids_akeep), intent(in) :: akeep
   class(ssids_fkeep_gpu), intent(inout) :: fkeep
   integer, intent(inout) :: local_job
   integer, intent(in) :: nrhs
   real(wp), dimension(ldx,nrhs), target, intent(inout) :: x
   integer, intent(in) :: ldx
   type(ssids_options), intent(in) :: options
   type(ssids_inform), intent(inout) :: inform

   integer :: i, r
   integer :: n

   type(cuda_settings_type) :: user_settings ! Stores user values we change
      ! temporarily

   integer :: cuda_error
   integer :: nchunk, num_threads
   integer, dimension(:,:), allocatable :: map
   integer, dimension(:), allocatable :: chunk_sa, chunk_en, fwd_ptr, fwd

   type(C_PTR) :: gpu_x
   type(C_PTR) :: gpu_scale
   type(C_PTR) :: gpu_invp

   n = akeep%n

   call push_ssids_cuda_settings(user_settings, cuda_error)
   if(cuda_error.ne.0) goto 200

   if ( options%presolve == 0 ) then

     if (allocated(fkeep%scaling)) then
        if (local_job == SSIDS_SOLVE_JOB_ALL .or. &
              local_job == SSIDS_SOLVE_JOB_FWD) then
           do r = 1, nrhs
              !x(1:n,r) = x(1:n,r) * fkeep%scaling(1:n)
              do i = 1, n
                 x(akeep%invp(i),r) = x(akeep%invp(i),r) * fkeep%scaling(i)
              end do
           end do
        end if
     end if

   else

     if (allocated(fkeep%scaling)) then
       cuda_error = cudaMalloc(gpu_scale, C_SIZEOF(fkeep%scaling(1:n)))
       if(cuda_error.ne.0) goto 200
       cuda_error = cudaMemcpy_h2d(gpu_scale, n, fkeep%scaling)
       if(cuda_error.ne.0) goto 200
       cuda_error = cudaMalloc(gpu_invp, C_SIZEOF(akeep%invp(1:n)))
       if(cuda_error.ne.0) goto 200
       cuda_error = cudaMemcpy_h2d(gpu_invp, n, akeep%invp)
       if(cuda_error.ne.0) goto 200
     end if

     cuda_error = cudaMalloc(gpu_x, nrhs*C_SIZEOF(x(1:n,1)))
     if(cuda_error.ne.0) goto 200
     if(n.eq.ldx) then
       cuda_error = cudaMemcpy_h2d(gpu_x, C_LOC(x), C_SIZEOF(x(1:n,1:nrhs)))
       if(cuda_error.ne.0) goto 200
     else
       cuda_error = cudaMemcpy2d(gpu_x, C_SIZEOF(x(1:n,1)), C_LOC(x), &
         C_SIZEOF(x(1:ldx,1)), C_SIZEOF(x(1:n,1)), int(nrhs, C_SIZE_T), &
         cudaMemcpyHostToDevice)
       if(cuda_error.ne.0) goto 200
     end if

     if(allocated(fkeep%scaling) .and. &
         (local_job == SSIDS_SOLVE_JOB_ALL .or. &
          local_job == SSIDS_SOLVE_JOB_FWD) ) then
       call scale( n, nrhs, gpu_x, n, gpu_scale, gpu_invp )
     end if
     
   end if

   ! Copy factor data to/from GPU as approriate (if required!)
   call ssids_move_data_inner(akeep, fkeep, options, inform)
   if(inform%flag.lt.0) then
      call pop_ssids_cuda_settings(user_settings, cuda_error)
      return
   endif

   ! We aim to have 4 chunks per thread to hopefully provide sufficient
   ! tree-level parallelism.
   num_threads = 1
!$ num_threads = omp_get_max_threads()
   call solve_calc_chunk(akeep%nnodes, fkeep%nodes, akeep%sparent, akeep%rptr, &
      4*num_threads, nchunk, chunk_sa, chunk_en, fwd_ptr, fwd, inform%stat)
   if(inform%stat.ne.0) goto 100

   if(options%use_gpu_solve .and. ( local_job.eq.SSIDS_SOLVE_JOB_FWD .or. &
         local_job.eq.SSIDS_SOLVE_JOB_ALL)) then
      allocate(map(0:akeep%n, num_threads), &
         stat=inform%stat)
      if(inform%stat.ne.0) goto 100
      if(options%presolve.eq.0) then
        call fwd_solve_gpu(fkeep%pos_def, akeep%child_ptr, akeep%child_list,   &
           akeep%n, akeep%invp, akeep%nnodes, fkeep%nodes, akeep%rptr,         &
           options%nstream, fkeep%stream_handle, fkeep%stream_data,            &
           fkeep%top_data, x, inform%stat, cuda_error)
        if(inform%stat.ne.0) goto 100
        if(cuda_error.ne.0) goto 200
      else
        call fwd_multisolve_gpu(akeep%nnodes, fkeep%nodes, akeep%rptr,     &
           options%nstream, fkeep%stream_handle, fkeep%stream_data,        &
           fkeep%top_data, nrhs, gpu_x, cuda_error, inform%stat)
        if(inform%stat.ne.0) goto 100
        if(cuda_error.ne.0) goto 200
      end if
      ! Fudge local_job if required to perform backwards solve
      if(local_job.eq.SSIDS_SOLVE_JOB_ALL) then
         if(fkeep%pos_def) then
            local_job = SSIDS_SOLVE_JOB_BWD
         else
            local_job = SSIDS_SOLVE_JOB_DIAG_BWD
         end if
      elseif(local_job.eq.SSIDS_SOLVE_JOB_FWD) then
         local_job = -1 ! done
      end if
   endif

   if(options%use_gpu_solve .and. local_job.eq.SSIDS_SOLVE_JOB_DIAG) then
      if(options%presolve.eq.0) then
         call d_solve_gpu(akeep%nnodes, akeep%sptr, options%nstream, &
            fkeep%stream_handle, fkeep%stream_data, fkeep%top_data, akeep%n, &
            akeep%invp, x, inform%stat, cuda_error)
         if(inform%stat.ne.0) goto 100
      else
         call bwd_multisolve_gpu(fkeep%pos_def, local_job, options%nstream, &
            fkeep%stream_handle, fkeep%stream_data, fkeep%top_data,   &
            nrhs, gpu_x, cuda_error)
      end if
      if(cuda_error.ne.0) goto 200
      local_job = -1 ! done
   endif

   ! Perform supernodal forward solve or diagonal solve (both in serial)
   call inner_solve(fkeep%pos_def, local_job, akeep%nnodes, &
      fkeep%nodes, akeep%sptr, akeep%rptr, akeep%rlist, akeep%invp, nrhs, &
      x, ldx, inform%stat)
   if (inform%stat .ne. 0) goto 100

   if( local_job.eq.SSIDS_SOLVE_JOB_DIAG_BWD .or. &
         local_job.eq.SSIDS_SOLVE_JOB_BWD .or. &
         local_job.eq.SSIDS_SOLVE_JOB_ALL ) then
      if(options%use_gpu_solve) then
        if(options%presolve.eq.0) then
           call bwd_solve_gpu(local_job, fkeep%pos_def, akeep%nnodes,      &
              akeep%sptr, options%nstream, fkeep%stream_handle,            &
              fkeep%stream_data, fkeep%top_data, akeep%invp, x,            &
              inform%stat, cuda_error)
           if(cuda_error.ne.0) goto 200
        else
           call bwd_multisolve_gpu(fkeep%pos_def, local_job, options%nstream, &
              fkeep%stream_handle, fkeep%stream_data, fkeep%top_data,   &
              nrhs, gpu_x, cuda_error)
           if(cuda_error.ne.0) goto 200
        end if
      else
         call subtree_bwd_solve(akeep%nnodes, 1, local_job, fkeep%pos_def,  &
            akeep%nnodes, fkeep%nodes, akeep%sptr, akeep%rptr, akeep%rlist, &
            akeep%invp, nrhs, x, ldx, inform%stat)
      endif
   end if
   if (inform%stat .ne. 0) goto 100

   if ( options%presolve == 0 ) then

     if (allocated(fkeep%scaling)) then
        if (local_job == SSIDS_SOLVE_JOB_ALL .or. &
              local_job == SSIDS_SOLVE_JOB_BWD .or. &
              local_job == SSIDS_SOLVE_JOB_DIAG_BWD) then
           do r = 1, nrhs
              !x(1:n,r) = x(1:n,r) * fkeep%scaling(1:n)
              do i = 1, n
                 x(akeep%invp(i),r) = x(akeep%invp(i),r) * fkeep%scaling(i)
              end do
           end do
        end if
     end if

   else

      if ( allocated(fkeep%scaling) .and. &
             (local_job == SSIDS_SOLVE_JOB_ALL .or. &
              local_job == SSIDS_SOLVE_JOB_BWD .or. &
              local_job == SSIDS_SOLVE_JOB_DIAG_BWD) ) then
         call scale( n, nrhs, gpu_x, n, gpu_scale, gpu_invp )
      end if

      if (allocated(fkeep%scaling)) then
         cuda_error = cudaFree( gpu_scale )
         if(cuda_error.ne.0) goto 200
         cuda_error = cudaFree( gpu_invp )
         if(cuda_error.ne.0) goto 200
      end if

      if(n.eq.ldx) then
        cuda_error = cudaMemcpy_d2h(C_LOC(x), gpu_x, nrhs*C_SIZEOF(x(1:n,1)))
        if(cuda_error.ne.0) goto 200
      else
        cuda_error = cudaMemcpy2d(C_LOC(x), C_SIZEOF(x(1:ldx,1)), gpu_x, &
          C_SIZEOF(x(1:n,1)), C_SIZEOF(x(1:n,1)), int(nrhs, C_SIZE_T), &
          cudaMemcpyDeviceToHost)
        if(cuda_error.ne.0) goto 200
      end if
      cuda_error = cudaFree(gpu_x)
      if(cuda_error.ne.0) goto 200

   end if

   call pop_ssids_cuda_settings(user_settings, cuda_error)
   if(cuda_error.ne.0) goto 200

   return

   100 continue
   inform%flag = SSIDS_ERROR_ALLOCATION
   call pop_ssids_cuda_settings(user_settings, cuda_error)
   return

   200 continue ! CUDA error
   inform%cuda_error = cuda_error
   inform%flag = SSIDS_ERROR_CUDA_UNKNOWN
   call pop_ssids_cuda_settings(user_settings, cuda_error)
   return
end subroutine inner_solve_gpu

!****************************************************************************

! Following function used to get around target requirement of C_LOC()
integer(C_INT) function copy_to_gpu_non_target(gpu_ptr, src, sz)
   type(C_PTR) :: gpu_ptr
   real(wp), dimension(*), target, intent(in) :: src
   integer(C_SIZE_T), intent(in) :: sz

   copy_to_gpu_non_target = cudaMemcpy_h2d(gpu_ptr, C_LOC(src), sz)
end function copy_to_gpu_non_target

!****************************************************************************

subroutine free_fkeep_gpu(fkeep, flag)
   class(ssids_fkeep_gpu), intent(inout) :: fkeep
   integer, intent(out) :: flag  ! Returns any cuda error value

   integer :: st, i

   ! Skip if nothing intialized
   if (.not.allocated(fkeep%nodes)) return

   ! Call superclass free first (sets flag to 0)
   call fkeep%ssids_fkeep%free(flag)

   !
   ! Now cleanup GPU-specific stuff
   !
   call free_gpu_type(fkeep%top_data, flag)
   if(allocated(fkeep%stream_data)) then
      do i = 1, size(fkeep%stream_data)
         call free_gpu_type(fkeep%stream_data(i), flag)
      end do
      deallocate(fkeep%stream_data, stat=st)
   endif

   ! Cleanup top-level presolve info
   if(C_ASSOCIATED(fkeep%gpu_rlist_with_delays)) then
      flag = cudaFree(fkeep%gpu_rlist_with_delays)
      fkeep%gpu_rlist_with_delays = C_NULL_PTR
      if(flag.ne.0) return
   endif
   if(C_ASSOCIATED(fkeep%gpu_clists)) then
      flag = cudaFree(fkeep%gpu_clists)
      fkeep%gpu_clists = C_NULL_PTR
      if(flag.ne.0) return
   endif
   if(C_ASSOCIATED(fkeep%gpu_clists_direct)) then
      flag = cudaFree(fkeep%gpu_clists)
      fkeep%gpu_clists = C_NULL_PTR
      if(flag.ne.0) return
   endif
   if(C_ASSOCIATED(fkeep%gpu_clen)) then
      flag = cudaFree(fkeep%gpu_clen)
      fkeep%gpu_clen = C_NULL_PTR
      if(flag.ne.0) return
   endif

   ! Release streams
   if(allocated(fkeep%stream_handle)) then
      do i = 1, size(fkeep%stream_handle)
         flag = cudaStreamDestroy(fkeep%stream_handle(i))
         if(flag.ne.0) return
      end do
      deallocate(fkeep%stream_handle, stat=st)
   endif
end subroutine free_fkeep_gpu

!
! Copies all gpu data back to host
!
subroutine ssids_move_data_inner(akeep, fkeep, options, inform)
   type(ssids_akeep), intent(in) :: akeep
   type(ssids_fkeep_gpu), intent(inout) :: fkeep
   type(ssids_options), intent(in) :: options
   type(ssids_inform), intent(inout) :: inform

   !integer :: lev
   integer :: cuda_error
   integer :: st

   ! We assume that the factor has been done on the GPU. Do we need to copy
   ! data back to host?
   if(options%use_gpu_solve) return ! Solve to be done on GPU, no movement
   if(fkeep%host_factors) return ! Data already moved

   ! Copy data as desired
   call copy_back_to_host(fkeep%host_factors, options%nstream, &
      fkeep%stream_data, &
      fkeep%top_data, fkeep%nodes, akeep%sptr, &
      akeep%rptr, fkeep%alloc, &
      cuda_error, st)
   if(st.ne.0) goto 100
   if(cuda_error.ne.0) goto 200

   return ! Normal return

   100 continue ! Fortran allocation error
   inform%flag = SSIDS_ERROR_ALLOCATION
   return

   200 continue ! CUDA error
   inform%cuda_error = cuda_error
   inform%flag = SSIDS_ERROR_CUDA_UNKNOWN
   return
end subroutine ssids_move_data_inner

subroutine copy_back_to_host(host_factors, nstream, stream_data, top_data, &
      nodes, sptr, rptr, alloc, cuda_error, st)
   logical, intent(out) :: host_factors
   integer, intent(in) :: nstream
   type(gpu_type), dimension(:), intent(in) :: stream_data
   type(gpu_type), intent(in) :: top_data
   type(node_type), dimension(*), intent(inout) :: nodes
   integer, dimension(*), intent(in) :: sptr
   integer(long), dimension(*), intent(in) :: rptr
   type(smalloc_type), intent(inout) :: alloc ! Contains actual memory
      ! allocations for L. Everything else (within the subtree) is just a
      ! pointer to this.
   integer, intent(out) :: cuda_error
   integer, intent(out) :: st

   integer :: stream

   host_factors = .true. ! Record that data has been copied to host

   st = 0

   do stream = 1, nstream
      call copy_stream_data_to_host(stream_data(stream), nodes, sptr, &
         rptr, alloc, cuda_error, st)
      if(cuda_error.ne.0 .or. st.ne.0) return
   end do
   call copy_stream_data_to_host(top_data, nodes, sptr, &
      rptr, alloc, cuda_error, st)
   if(cuda_error.ne.0 .or. st.ne.0) return

end subroutine copy_back_to_host

subroutine copy_stream_data_to_host(stream_data, &
      nodes, sptr, rptr, alloc, cuda_error, st)
   type(gpu_type), intent(in) :: stream_data
   type(node_type), dimension(*), intent(inout) :: nodes
   integer, dimension(*), intent(in) :: sptr
   integer(long), dimension(*), intent(in) :: rptr
   type(smalloc_type), intent(inout) :: alloc ! Contains actual memory
      ! allocations for L. Everything else (within the subtree) is just a
      ! pointer to this.
   integer, intent(out) :: cuda_error
   integer, intent(out) :: st

   integer :: llist, lev, node, ndelay, blkn, blkm
   integer(long) :: offp
   integer(long) :: level_size
   real(wp), dimension(:), allocatable, target :: work
   real(wp), dimension(:), pointer :: lcol
   type(C_PTR) :: ptr_levL
   
   ! Initialize return values
   cuda_error = 0
   st = 0

   ! Shortcut empty streams (occurs for v. small matrices)
   if(stream_data%num_levels.eq.0) return

   ! Copy one level at a time, then split into nodes
   do lev = 1, stream_data%num_levels
    
      level_size = 0
      do llist = stream_data%lvlptr(lev), stream_data%lvlptr(lev + 1) - 1
         node = stream_data%lvllist(llist)
         ndelay = nodes(node)%ndelay
         blkn = sptr(node+1) - sptr(node) + ndelay
         blkm = int(rptr(node+1) - rptr(node)) + ndelay
         call smalloc(alloc, nodes(node)%lcol, (blkn+0_long)*blkm+2*blkn, &
            nodes(node)%rsmptr, nodes(node)%rsmsa, st)
         if (st .ne. 0) return
         level_size = level_size + (blkm + 2_long)*blkn
      end do
      
      allocate(work(level_size), stat=st)
      if(st.ne.0) return
      
      ptr_levL = c_ptr_plus( stream_data%values_L(lev)%ptr_levL, 0_C_SIZE_T )
      cuda_error = cudaMemcpy_d2h(C_LOC(work), ptr_levL, &
         C_SIZEOF(work(1:level_size)))
      if(cuda_error.ne.0) return

      do llist = stream_data%lvlptr(lev), stream_data%lvlptr(lev + 1) - 1
         node = stream_data%lvllist(llist)
         ndelay = nodes(node)%ndelay
         blkn = sptr(node+1) - sptr(node) + ndelay
         blkm = int(rptr(node+1) - rptr(node)) + ndelay
         lcol => nodes(node)%lcol
         offp = stream_data%off_L(node)
         call dcopy( (blkm + 2)*blkn, work(offp + 1), 1, lcol, 1 )
      end do
      
      deallocate ( work )
      
   end do
end subroutine copy_stream_data_to_host

end module spral_ssids_fkeep_gpu
